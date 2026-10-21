/// Cloud storage boundary for sync, plus the Firestore document format.
///
/// Layout (per signed-in user, never shared):
///   users/{uid}/songs/{songSyncId}
///   users/{uid}/folders/{folderSyncId}
///   users/{uid}/folderSongs/{folderSyncId}_{songSyncId}
///
/// Documents are never hard-deleted: a deletion is `deleted: true` +
/// `deletedAtMs`. Local integer ids never appear in the cloud.
///
/// The real implementation (Firestore, Android only) lives in
/// `sync/android/firestore_cloud_sync_backend.dart`; tests use a fake that
/// stores the same document maps.
library;

import 'sync_records.dart';

abstract final class CloudCollections {
  static const songs = 'songs';
  static const folders = 'folders';
  static const folderSongs = 'folderSongs';
}

/// Placeholder for "the server's time" in a document map. The Firestore
/// backend replaces it with `FieldValue.serverTimestamp()`.
class CloudServerTimestamp {
  const CloudServerTimestamp();
}

const cloudServerTimestamp = CloudServerTimestamp();

/// One document write. [merge] = keep fields the map doesn't mention
/// (used for deletion markers, so an existing document keeps its content).
class CloudWrite {
  final String collection;
  final String docId;
  final Map<String, Object?> data;
  final bool merge;

  /// Identifies what was written (`song:<id>`, `folder:<id>`,
  /// `fs:<docId>`), so the engine knows which rows it uploaded.
  final String entityKey;

  const CloudWrite({
    required this.collection,
    required this.docId,
    required this.data,
    required this.merge,
    required this.entityKey,
  });

  bool get isDeletion => data['deleted'] == true;
}

enum CloudSyncErrorKind { network, permissionDenied, other }

/// A cloud read/write failed. [detail] is for logs only.
class CloudSyncBackendException implements Exception {
  final CloudSyncErrorKind kind;
  final String detail;

  const CloudSyncBackendException(this.kind, this.detail);

  @override
  String toString() => 'CloudSyncBackendException(${kind.name}: $detail)';
}

abstract class CloudSyncBackend {
  /// Most writes per [commit] call (Firestore allows 500).
  static const maxBatchWrites = 400;

  /// Reads every song, folder and membership document of [uid], straight
  /// from the server (no offline cache). Throws [CloudSyncBackendException].
  Future<CloudSnapshot> fetchAll(String uid);

  /// Applies [writes] (at most [maxBatchWrites]) atomically. Re-running
  /// the same writes is harmless: document ids are deterministic.
  Future<void> commit(String uid, List<CloudWrite> writes);

  /// Documents whose server write time (`serverUpdatedAt`) is at or after
  /// the given time, per collection; null = the whole collection. Parsed
  /// records carry [CloudSong.serverUpdatedAtMs] etc. From the server only.
  Future<CloudSnapshot> fetchChanged(
    String uid, {
    int? songsSinceMs,
    int? foldersSinceMs,
    int? folderSongsSinceMs,
  });

  /// The current cloud documents with these ids (missing ones are simply
  /// absent from the result). From the server only.
  Future<CloudSnapshot> fetchByIds(
    String uid, {
    Iterable<String> songIds = const [],
    Iterable<String> folderIds = const [],
    Iterable<String> membershipIds = const [],
  });
}

// ---------------------------------------------------------------------------
// Document format
// ---------------------------------------------------------------------------

String songEntityKey(String syncId) => 'song:$syncId';
String folderEntityKey(String syncId) => 'folder:$syncId';
String membershipEntityKey(String docId) => 'fs:$docId';

abstract final class CloudDocCodec {
  static CloudWrite putSong(String syncId, SongData d, int updatedAtMs) =>
      CloudWrite(
        collection: CloudCollections.songs,
        docId: syncId,
        entityKey: songEntityKey(syncId),
        merge: false,
        data: {
          'syncId': syncId,
          'provider': d.karaokeType,
          'songNumber': d.songNumber,
          'title': d.title,
          'artist': d.artist,
          'keyType': d.keyType,
          'keyOffset': d.keyOffset,
          'difficulty': d.difficulty,
          'practiceStatus': d.practiceStatus,
          'memo': d.memo,
          'favorite': d.favorite,
          'searchAliases': List<String>.of(d.searchAliases),
          'createdAt': d.createdAt,
          'updatedAt': d.updatedAt,
          'updatedAtMs': updatedAtMs,
          'serverUpdatedAt': cloudServerTimestamp,
          'deleted': false,
          'deletedAtMs': null,
        },
      );

  static CloudWrite putFolder(String syncId, FolderData d, int updatedAtMs) =>
      CloudWrite(
        collection: CloudCollections.folders,
        docId: syncId,
        entityKey: folderEntityKey(syncId),
        merge: false,
        data: {
          'syncId': syncId,
          'name': d.name,
          'createdAt': d.createdAt,
          'updatedAt': d.updatedAt,
          'updatedAtMs': updatedAtMs,
          'serverUpdatedAt': cloudServerTimestamp,
          'deleted': false,
          'deletedAtMs': null,
        },
      );

  static CloudWrite putMembership(
    String folderSyncId,
    String songSyncId,
    String addedAt,
    int updatedAtMs, {
    required int revision,
  }) {
    final docId = membershipDocId(folderSyncId, songSyncId);
    return CloudWrite(
      collection: CloudCollections.folderSongs,
      docId: docId,
      entityKey: membershipEntityKey(docId),
      merge: false,
      data: {
        'folderSyncId': folderSyncId,
        'songSyncId': songSyncId,
        'addedAt': addedAt,
        'revision': revision,
        'updatedAtMs': updatedAtMs,
        'serverUpdatedAt': cloudServerTimestamp,
        'deleted': false,
        'deletedAtMs': null,
      },
    );
  }

  static CloudWrite deleteSong(String syncId, int deletedAtMs) => CloudWrite(
        collection: CloudCollections.songs,
        docId: syncId,
        entityKey: songEntityKey(syncId),
        merge: true,
        data: {'syncId': syncId, ..._deletionFields(deletedAtMs)},
      );

  static CloudWrite deleteFolder(String syncId, int deletedAtMs) => CloudWrite(
        collection: CloudCollections.folders,
        docId: syncId,
        entityKey: folderEntityKey(syncId),
        merge: true,
        data: {'syncId': syncId, ..._deletionFields(deletedAtMs)},
      );

  /// Deletion marker for a membership at [revision]: the removal's own
  /// revision, or (when a deleted song/folder takes the membership with
  /// it) the cloud document's current revision — same generation, so the
  /// deletion wins without claiming a newer user change.
  static CloudWrite deleteMembership(
    String folderSyncId,
    String songSyncId,
    int deletedAtMs, {
    required int revision,
  }) {
    final docId = membershipDocId(folderSyncId, songSyncId);
    return CloudWrite(
      collection: CloudCollections.folderSongs,
      docId: docId,
      entityKey: membershipEntityKey(docId),
      merge: true,
      data: {
        'folderSyncId': folderSyncId,
        'songSyncId': songSyncId,
        'revision': revision,
        ..._deletionFields(deletedAtMs),
      },
    );
  }

  static Map<String, Object?> _deletionFields(int deletedAtMs) => {
        'deleted': true,
        'deletedAtMs': deletedAtMs,
        'updatedAtMs': deletedAtMs,
        'serverUpdatedAt': cloudServerTimestamp,
      };

  // --- parsing -------------------------------------------------------------

  /// Null if the document can't be tied to a song (id mismatch/missing).
  static CloudSong? parseSong(String docId, Map<String, Object?> m) {
    if (!_idMatches(docId, m['syncId'])) return null;
    final deleted = m['deleted'] == true;
    final title = m['title'];
    final createdAt = m['createdAt'];
    final updatedAt = m['updatedAt'];
    SongData? data;
    if (title is String && createdAt is String && updatedAt is String) {
      data = SongData(
        karaokeType: _str(m['provider']) ?? 'TJ',
        songNumber: _str(m['songNumber']) ?? '',
        title: title,
        artist: _str(m['artist']),
        keyType: _str(m['keyType']),
        keyOffset: _int(m['keyOffset']) ?? 0,
        difficulty: _str(m['difficulty']),
        practiceStatus: _str(m['practiceStatus']),
        memo: _str(m['memo']),
        favorite: m['favorite'] == true,
        searchAliases: m['searchAliases'] is List
            ? (m['searchAliases'] as List).map((e) => e.toString()).toList()
            : const [],
        createdAt: createdAt,
        updatedAt: updatedAt,
      );
    } else if (!deleted) {
      return null; // live but unusable: ignored rather than guessed
    }
    return CloudSong(
      syncId: docId,
      data: data,
      updatedAtMs: _int(m['updatedAtMs']) ?? 0,
      deleted: deleted,
      deletedAtMs: _int(m['deletedAtMs']),
      serverUpdatedAtMs: _int(m['serverUpdatedAt']),
    );
  }

  static CloudFolder? parseFolder(String docId, Map<String, Object?> m) {
    if (!_idMatches(docId, m['syncId'])) return null;
    final deleted = m['deleted'] == true;
    final name = m['name'];
    final createdAt = m['createdAt'];
    final updatedAt = m['updatedAt'];
    FolderData? data;
    if (name is String && createdAt is String && updatedAt is String) {
      data = FolderData(name: name, createdAt: createdAt, updatedAt: updatedAt);
    } else if (!deleted) {
      return null;
    }
    return CloudFolder(
      syncId: docId,
      data: data,
      updatedAtMs: _int(m['updatedAtMs']) ?? 0,
      deleted: deleted,
      deletedAtMs: _int(m['deletedAtMs']),
      serverUpdatedAtMs: _int(m['serverUpdatedAt']),
    );
  }

  static CloudMembership? parseMembership(
    String docId,
    Map<String, Object?> m,
  ) {
    final folderSyncId = _str(m['folderSyncId']);
    final songSyncId = _str(m['songSyncId']);
    if (folderSyncId == null || songSyncId == null) return null;
    if (folderSyncId.isEmpty || songSyncId.isEmpty) return null;
    if (docId != membershipDocId(folderSyncId, songSyncId)) return null;
    final deleted = m['deleted'] == true;
    final addedAt = _str(m['addedAt']);
    if (!deleted && addedAt == null) return null;
    return CloudMembership(
      folderSyncId: folderSyncId,
      songSyncId: songSyncId,
      addedAt: addedAt,
      updatedAtMs: _int(m['updatedAtMs']) ?? 0,
      deleted: deleted,
      deletedAtMs: _int(m['deletedAtMs']),
      serverUpdatedAtMs: _int(m['serverUpdatedAt']),
      revision: _int(m['revision']),
    );
  }

  static bool _idMatches(String docId, Object? field) =>
      docId.isNotEmpty && field is String && field == docId;

  static String? _str(Object? v) => v is String ? v : null;

  static int? _int(Object? v) => v is int ? v : (v is num ? v.toInt() : null);
}
