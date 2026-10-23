import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';

import '../account_data_deletion.dart';
import '../cloud_sync_backend.dart';
import 'firestore_cloud_sync_backend.dart';

/// Hard-deletes a user's cloud backup for account deletion (Phase B-5).
/// Android only (imported solely from `account/android/`).
///
/// Separate from [FirestoreCloudSyncBackend] on purpose: normal sync has no
/// delete call at all and keeps using `deleted: true` markers. This class
/// only ever addresses `users/{uid}/songs|folders|folderSongs` of the uid
/// it is given (the signed-in, re-authenticated account), and the security
/// rules allow a hard delete only for the owner.
class FirestoreAccountDataEraser implements CloudAccountDataEraser {
  static const _readTimeout = Duration(seconds: 30);
  static const _writeTimeout = Duration(seconds: 30);

  /// Safety stop against an endless loop (e.g. another device re-uploading
  /// as fast as we delete): 1000 batches = 400k documents.
  static const _maxBatches = 1000;

  final int batchSize;

  FirestoreAccountDataEraser({
    this.batchSize = CloudAccountDataEraser.maxBatchDeletes,
  }) : assert(
         batchSize > 0 && batchSize <= CloudAccountDataEraser.maxBatchDeletes,
       );

  static const _server = GetOptions(source: Source.server);

  DocumentReference<Map<String, dynamic>> _block(String uid) => syncFirestore()
      .collection(CloudAccountDataEraser.blocksCollection)
      .doc(uid);

  @override
  Future<void> ensureDeletionBlock(String uid) async {
    if (uid.isEmpty) throw ArgumentError('empty uid');
    try {
      final ref = _block(uid);
      final existing = await ref.get(_server).timeout(_readTimeout);
      if (!existing.exists) {
        // Only field: the server time. No email, name or song data. The
        // rules allow this create once and never an update/delete.
        await ref
            .set({'deletedAt': FieldValue.serverTimestamp()})
            .timeout(_writeTimeout);
      }
      final check = await ref.get(_server).timeout(_readTimeout);
      if (!check.exists) {
        throw const CloudSyncBackendException(
          CloudSyncErrorKind.other,
          'deletion block not found after create',
        );
      }
    } on FirebaseException catch (e) {
      throw mapFirestoreError(e);
    } on TimeoutException {
      throw const CloudSyncBackendException(
        CloudSyncErrorKind.network,
        'deletion block timeout',
      );
    }
  }

  @override
  Future<bool> deletionBlockExists(String uid) async {
    try {
      return (await _block(uid).get(_server).timeout(_readTimeout)).exists;
    } on FirebaseException catch (e) {
      throw mapFirestoreError(e);
    } on TimeoutException {
      throw const CloudSyncBackendException(
        CloudSyncErrorKind.network,
        'deletion block timeout',
      );
    }
  }

  @override
  Future<int> deleteAllUserData(
    String uid, {
    void Function(int deletedSoFar)? onBatchCommitted,
  }) async {
    if (uid.isEmpty) throw ArgumentError('empty uid');
    final firestore = syncFirestore();
    final user = firestore.collection('users').doc(uid);
    var deleted = 0;
    var batches = 0;
    try {
      // Memberships first, then folders, then songs (any order would do for
      // a hard delete; this one never leaves a membership without its
      // folder/song if a run stops halfway).
      for (final name in const [
        CloudCollections.folderSongs,
        CloudCollections.folders,
        CloudCollections.songs,
      ]) {
        final col = user.collection(name);
        while (true) {
          final snap = await col
              .limit(batchSize)
              .get(_server)
              .timeout(_readTimeout);
          if (snap.docs.isEmpty) break;
          if (++batches > _maxBatches) {
            throw const CloudSyncBackendException(
              CloudSyncErrorKind.other,
              'too many delete batches',
            );
          }
          final batch = firestore.batch();
          for (final d in snap.docs) {
            batch.delete(d.reference);
          }
          await batch.commit().timeout(_writeTimeout);
          deleted += snap.docs.length;
          onBatchCommitted?.call(deleted);
        }
      }
      return deleted;
    } on FirebaseException catch (e) {
      throw mapFirestoreError(e);
    } on TimeoutException {
      throw const CloudSyncBackendException(
        CloudSyncErrorKind.network,
        'delete timeout',
      );
    }
  }
}
