import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';

import '../cloud_sync_backend.dart';
import '../sync_records.dart';

/// Firestore implementation of [CloudSyncBackend]. Android only (imported
/// solely from `account/android/`, so it never reaches the Web build).
///
/// Firestore's offline persistence is turned off: change tracking lives in
/// SQLite (`sync_dirty`), and reads must come from the server so sync
/// decisions never run on a stale cache.
class FirestoreCloudSyncBackend implements CloudSyncBackend {
  static const _readTimeout = Duration(seconds: 30);
  static const _writeTimeout = Duration(seconds: 30);

  /// Firestore's limit for `whereIn`.
  static const _idChunk = 30;

  static bool _configured = false;

  FirebaseFirestore get _firestore {
    final db = FirebaseFirestore.instance;
    if (!_configured) {
      // Must be set before the first Firestore call.
      db.settings = const Settings(persistenceEnabled: false);
      _configured = true;
    }
    return db;
  }

  CollectionReference<Map<String, dynamic>> _col(String uid, String name) =>
      _firestore.collection('users').doc(uid).collection(name);

  static const _server = GetOptions(source: Source.server);

  @override
  Future<CloudSnapshot> fetchAll(String uid) => fetchChanged(uid);

  @override
  Future<CloudSnapshot> fetchChanged(
    String uid, {
    int? songsSinceMs,
    int? foldersSinceMs,
    int? folderSongsSinceMs,
  }) {
    Query<Map<String, dynamic>> q(String name, int? sinceMs) {
      final col = _col(uid, name);
      if (sinceMs == null) return col;
      return col.where(
        'serverUpdatedAt',
        isGreaterThanOrEqualTo: Timestamp.fromMillisecondsSinceEpoch(sinceMs),
      );
    }

    return _guardRead(() async {
      final results = await Future.wait([
        q(CloudCollections.songs, songsSinceMs).get(_server),
        q(CloudCollections.folders, foldersSinceMs).get(_server),
        q(CloudCollections.folderSongs, folderSongsSinceMs).get(_server),
      ]).timeout(_readTimeout);
      return _parse(results[0].docs, results[1].docs, results[2].docs);
    });
  }

  @override
  Future<CloudSnapshot> fetchByIds(
    String uid, {
    Iterable<String> songIds = const [],
    Iterable<String> folderIds = const [],
    Iterable<String> membershipIds = const [],
  }) {
    Future<List<QueryDocumentSnapshot<Map<String, dynamic>>>> byIds(
      String name,
      Iterable<String> ids,
    ) async {
      final list = ids.toSet().toList();
      final out = <QueryDocumentSnapshot<Map<String, dynamic>>>[];
      for (var i = 0; i < list.length; i += _idChunk) {
        final chunk = list.sublist(
          i,
          i + _idChunk < list.length ? i + _idChunk : list.length,
        );
        final snap = await _col(uid, name)
            .where(FieldPath.documentId, whereIn: chunk)
            .get(_server)
            .timeout(_readTimeout);
        out.addAll(snap.docs);
      }
      return out;
    }

    return _guardRead(() async {
      final songs = await byIds(CloudCollections.songs, songIds);
      final folders = await byIds(CloudCollections.folders, folderIds);
      final members = await byIds(CloudCollections.folderSongs, membershipIds);
      return _parse(songs, folders, members);
    });
  }

  @override
  Future<void> commit(String uid, List<CloudWrite> writes) async {
    if (writes.isEmpty) return;
    assert(writes.length <= CloudSyncBackend.maxBatchWrites);
    try {
      final batch = _firestore.batch();
      for (final w in writes) {
        final ref = _col(uid, w.collection).doc(w.docId);
        final data = <String, dynamic>{
          for (final e in w.data.entries)
            e.key: e.value is CloudServerTimestamp
                ? FieldValue.serverTimestamp()
                : e.value,
        };
        if (w.merge) {
          batch.set(ref, data, SetOptions(merge: true));
        } else {
          batch.set(ref, data);
        }
      }
      // Without persistence a commit only completes on server ack; a lost
      // connection would otherwise wait forever. A late success after the
      // timeout is harmless (same deterministic documents on retry).
      await batch.commit().timeout(_writeTimeout);
    } on FirebaseException catch (e) {
      throw _map(e);
    } on TimeoutException {
      throw const CloudSyncBackendException(
        CloudSyncErrorKind.network,
        'write timeout',
      );
    }
  }

  Future<CloudSnapshot> _guardRead(Future<CloudSnapshot> Function() read) async {
    try {
      return await read();
    } on FirebaseException catch (e) {
      throw _map(e);
    } on TimeoutException {
      throw const CloudSyncBackendException(
        CloudSyncErrorKind.network,
        'read timeout',
      );
    }
  }

  /// Converts `serverUpdatedAt` to epoch ms before handing the map to the
  /// shared codec.
  static Map<String, Object?> _plain(Map<String, dynamic> data) {
    final ts = data['serverUpdatedAt'];
    if (ts is! Timestamp) return data;
    return {...data, 'serverUpdatedAt': ts.millisecondsSinceEpoch};
  }

  static CloudSnapshot _parse(
    List<QueryDocumentSnapshot<Map<String, dynamic>>> songDocs,
    List<QueryDocumentSnapshot<Map<String, dynamic>>> folderDocs,
    List<QueryDocumentSnapshot<Map<String, dynamic>>> memberDocs,
  ) {
    final songs = <String, CloudSong>{};
    for (final d in songDocs) {
      final s = CloudDocCodec.parseSong(d.id, _plain(d.data()));
      if (s != null) songs[s.syncId] = s;
    }
    final folders = <String, CloudFolder>{};
    for (final d in folderDocs) {
      final f = CloudDocCodec.parseFolder(d.id, _plain(d.data()));
      if (f != null) folders[f.syncId] = f;
    }
    final memberships = <String, CloudMembership>{};
    for (final d in memberDocs) {
      final m = CloudDocCodec.parseMembership(d.id, _plain(d.data()));
      if (m != null) memberships[m.key] = m;
    }
    return CloudSnapshot(
      songs: songs,
      folders: folders,
      memberships: memberships,
    );
  }

  static CloudSyncBackendException _map(FirebaseException e) {
    final kind = switch (e.code) {
      'unavailable' || 'deadline-exceeded' => CloudSyncErrorKind.network,
      'permission-denied' || 'unauthenticated' =>
        CloudSyncErrorKind.permissionDenied,
      _ => CloudSyncErrorKind.other,
    };
    return CloudSyncBackendException(kind, 'firestore ${e.code}');
  }
}
