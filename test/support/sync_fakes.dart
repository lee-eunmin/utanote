import 'dart:async';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:utanote/account/auth_gateway.dart';
import 'package:utanote/sync/cloud_sync_backend.dart';
import 'package:utanote/sync/sync_records.dart';

/// In-memory stand-in for Firestore, storing the same document maps the
/// real backend writes. Mirrors the security rules that matter to sync:
/// per-uid isolation, no hard deletes (there is no delete API at all) and
/// "a deleted document can't be revived" — a write that tries is rejected
/// like Firestore would (permission denied), failing the whole batch.
class FakeCloudBackend implements CloudSyncBackend {
  /// uid → collection → docId → data
  final Map<String, Map<String, Map<String, Map<String, Object?>>>> users = {};

  int fetchCount = 0;
  int commitCount = 0;
  final List<int> batchSizes = [];

  /// 1-based index of the commit that fails (before writing anything).
  int? failOnCommit;
  Object commitError = const CloudSyncBackendException(
    CloudSyncErrorKind.network,
    'fake offline',
  );

  Object? fetchError;

  /// If set, fetchAll waits for it (to test in-flight behaviour).
  Completer<void>? fetchGate;

  /// Runs before each commit is applied (e.g. to simulate a user edit
  /// while the upload is in flight).
  Future<void> Function(int commitIndex)? beforeCommit;

  /// Fake server clock (epoch ms) for serverUpdatedAt; advances by
  /// [clockStepMs] per written document.
  int serverClockMs = 1000000;
  int clockStepMs = 1000;

  int fetchChangedCount = 0;
  int fetchByIdsCount = 0;

  /// The since values of the last fetchChanged call.
  List<int?> lastSince = const [];

  Map<String, Map<String, Object?>> col(String uid, String name) =>
      users.putIfAbsent(uid, () => {}).putIfAbsent(name, () => {});

  int docCount(String uid, String collection) => col(uid, collection).length;

  Map<String, Object?>? docOf(String uid, String collection, String id) =>
      users[uid]?[collection]?[id];

  /// Seeds a document directly (no rules), e.g. data from another device.
  void seed(String uid, CloudWrite w) => _apply(uid, w);

  @override
  Future<CloudSnapshot> fetchAll(String uid) async {
    fetchCount++;
    if (fetchGate != null) await fetchGate!.future;
    if (fetchError != null) throw fetchError!;
    return _snapshot(uid, (_, _) => true);
  }

  @override
  Future<CloudSnapshot> fetchChanged(
    String uid, {
    int? songsSinceMs,
    int? foldersSinceMs,
    int? folderSongsSinceMs,
  }) async {
    fetchCount++;
    fetchChangedCount++;
    lastSince = [songsSinceMs, foldersSinceMs, folderSongsSinceMs];
    if (fetchGate != null) await fetchGate!.future;
    if (fetchError != null) throw fetchError!;
    bool after(int? since, Map<String, Object?> m) {
      if (since == null) return true;
      final t = m['serverUpdatedAt'];
      return t is int && t >= since;
    }

    return _snapshot(uid, (collection, m) => switch (collection) {
          CloudCollections.songs => after(songsSinceMs, m),
          CloudCollections.folders => after(foldersSinceMs, m),
          _ => after(folderSongsSinceMs, m),
        });
  }

  @override
  Future<CloudSnapshot> fetchByIds(
    String uid, {
    Iterable<String> songIds = const [],
    Iterable<String> folderIds = const [],
    Iterable<String> membershipIds = const [],
  }) async {
    fetchCount++;
    fetchByIdsCount++;
    if (fetchByIdsError != null) throw fetchByIdsError!;
    final wanted = {
      CloudCollections.songs: songIds.toSet(),
      CloudCollections.folders: folderIds.toSet(),
      CloudCollections.folderSongs: membershipIds.toSet(),
    };
    final out = _snapshot(uid, (_, _) => true);
    return CloudSnapshot(
      songs: {
        for (final e in out.songs.entries)
          if (wanted[CloudCollections.songs]!.contains(e.key)) e.key: e.value,
      },
      folders: {
        for (final e in out.folders.entries)
          if (wanted[CloudCollections.folders]!.contains(e.key)) e.key: e.value,
      },
      memberships: {
        for (final e in out.memberships.entries)
          if (wanted[CloudCollections.folderSongs]!.contains(e.key))
            e.key: e.value,
      },
    );
  }

  Object? fetchByIdsError;

  CloudSnapshot _snapshot(
    String uid,
    bool Function(String collection, Map<String, Object?> data) include,
  ) {
    final songs = <String, CloudSong>{};
    col(uid, CloudCollections.songs).forEach((id, m) {
      if (!include(CloudCollections.songs, m)) return;
      final s = CloudDocCodec.parseSong(id, m);
      if (s != null) songs[id] = s;
    });
    final folders = <String, CloudFolder>{};
    col(uid, CloudCollections.folders).forEach((id, m) {
      if (!include(CloudCollections.folders, m)) return;
      final f = CloudDocCodec.parseFolder(id, m);
      if (f != null) folders[id] = f;
    });
    final memberships = <String, CloudMembership>{};
    col(uid, CloudCollections.folderSongs).forEach((id, m) {
      if (!include(CloudCollections.folderSongs, m)) return;
      final x = CloudDocCodec.parseMembership(id, m);
      if (x != null) memberships[id] = x;
    });
    return CloudSnapshot(
      songs: songs,
      folders: folders,
      memberships: memberships,
    );
  }

  @override
  Future<void> commit(String uid, List<CloudWrite> writes) async {
    commitCount++;
    batchSizes.add(writes.length);
    if (writes.length > CloudSyncBackend.maxBatchWrites) {
      throw StateError('batch too large: ${writes.length}');
    }
    if (beforeCommit != null) await beforeCommit!(commitCount);
    if (failOnCommit == commitCount) throw commitError;
    // Rules check for the whole batch first: atomic like Firestore.
    for (final w in writes) {
      final existing = col(uid, w.collection)[w.docId];
      if (w.collection == CloudCollections.folderSongs) {
        _checkMembershipRules(w, existing);
        continue;
      }
      if (existing != null &&
          existing['deleted'] == true &&
          w.data['deleted'] != true) {
        throw CloudSyncBackendException(
          CloudSyncErrorKind.permissionDenied,
          'revive ${w.collection}/${w.docId}',
        );
      }
    }
    for (final w in writes) {
      _apply(uid, w);
    }
  }

  /// Same as firestore.rules for folderSongs: every write carries an int
  /// `revision` that never goes down; a deleted document becomes live
  /// again only with a strictly higher revision (an explicit re-add).
  /// Documents from before revisions count as live 1 / deleted 2.
  static void _checkMembershipRules(
    CloudWrite w,
    Map<String, Object?>? existing,
  ) {
    void deny(String why) => throw CloudSyncBackendException(
          CloudSyncErrorKind.permissionDenied,
          '$why ${w.collection}/${w.docId}',
        );
    final merged = {...?(w.merge ? existing : null), ...w.data};
    final newRev = merged['revision'];
    if (newRev is! int) deny('no revision');
    if (existing == null) return;
    final wasDeleted = existing['deleted'] == true;
    final oldRev = (existing['revision'] as int?) ?? (wasDeleted ? 2 : 1);
    final nowDeleted = merged['deleted'] == true;
    if ((newRev as int) < oldRev) deny('lower revision');
    if (wasDeleted && !nowDeleted && newRev <= oldRev) deny('revive');
  }

  void _apply(String uid, CloudWrite w) {
    final data = {
      for (final e in w.data.entries)
        e.key: e.value is CloudServerTimestamp
            ? (serverClockMs += clockStepMs)
            : e.value,
    };
    final c = col(uid, w.collection);
    if (w.merge && c[w.docId] != null) {
      c[w.docId] = {...c[w.docId]!, ...data};
    } else {
      c[w.docId] = data;
    }
  }
}

/// Every row of the user-data tables, for "nothing changed" assertions.
Future<Map<String, List<Map<String, Object?>>>> dumpUserTables(
  DatabaseExecutor db,
) async {
  return {
    'songs': await db.query('songs', orderBy: 'id'),
    'folders': await db.query('folders', orderBy: 'id'),
    'folder_songs':
        await db.query('folder_songs', orderBy: 'folder_id, song_id'),
    'sync_tombstones': await db.query(
      'sync_tombstones',
      orderBy: 'entity_type, sync_id, related_sync_id',
    ),
  };
}

Future<Map<String, String?>> dumpSyncMeta(DatabaseExecutor db) async {
  final rows = await db.query('sync_meta');
  return {for (final r in rows) r['key'] as String: r['value'] as String?};
}

/// Minimal sign-in fake (Firebase-like stream behaviour).
class FakeAuth implements AuthGateway {
  final users = StreamController<AccountUser?>.broadcast();
  AccountUser next;

  FakeAuth(this.next);

  @override
  Future<bool> initialize() async => true;

  @override
  Stream<AccountUser?> userChanges() => users.stream;

  @override
  Future<AccountUser> signInWithGoogle() async {
    users.add(next);
    return next;
  }

  @override
  Future<void> signOut() async => users.add(null);
}

/// Song content helper for seeding the fake cloud.
SongData songData(
  String title, {
  String number = '100',
  String createdAt = '2024-01-01T00:00:00.000',
  String updatedAt = '2024-01-01T00:00:00.000',
  String karaokeType = 'TJ',
  String? artist,
}) =>
    SongData(
      karaokeType: karaokeType,
      songNumber: number,
      title: title,
      artist: artist,
      createdAt: createdAt,
      updatedAt: updatedAt,
    );

FolderData folderData(String name) => FolderData(
      name: name,
      createdAt: '2024-01-01T00:00:00.000',
      updatedAt: '2024-01-01T00:00:00.000',
    );
