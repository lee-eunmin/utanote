import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';

import '../cloud_sync_backend.dart';
import '../sync_records.dart';

/// Firestore implementation of [CloudSyncBackend]. Android only (imported
/// solely from `account/android/`, so it never reaches the Web build).
///
/// Firestore's offline persistence is turned off: change tracking lives in
/// SQLite (`sync_dirty`), and reads must come from the server so the
/// initial-sync decision never runs on a stale cache.
class FirestoreCloudSyncBackend implements CloudSyncBackend {
  static const _readTimeout = Duration(seconds: 30);
  static const _writeTimeout = Duration(seconds: 30);

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

  @override
  Future<CloudSnapshot> fetchAll(String uid) async {
    try {
      const server = GetOptions(source: Source.server);
      final results = await Future.wait([
        _col(uid, CloudCollections.songs).get(server),
        _col(uid, CloudCollections.folders).get(server),
        _col(uid, CloudCollections.folderSongs).get(server),
      ]).timeout(_readTimeout);

      final songs = <String, CloudSong>{};
      for (final d in results[0].docs) {
        final s = CloudDocCodec.parseSong(d.id, d.data());
        if (s != null) songs[s.syncId] = s;
      }
      final folders = <String, CloudFolder>{};
      for (final d in results[1].docs) {
        final f = CloudDocCodec.parseFolder(d.id, d.data());
        if (f != null) folders[f.syncId] = f;
      }
      final memberships = <String, CloudMembership>{};
      for (final d in results[2].docs) {
        final m = CloudDocCodec.parseMembership(d.id, d.data());
        if (m != null) memberships[m.key] = m;
      }
      return CloudSnapshot(
        songs: songs,
        folders: folders,
        memberships: memberships,
      );
    } on FirebaseException catch (e) {
      throw _map(e);
    } on TimeoutException {
      throw const CloudSyncBackendException(
        CloudSyncErrorKind.network,
        'read timeout',
      );
    }
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
