/// Account deletion (Phase B-5): pure interfaces shared by the account
/// layer, the SQLite store and the Firestore eraser. No Firebase/SQLite
/// types here.
///
/// Unlike normal sync (which never hard-deletes and marks deletions with
/// `deleted: true`), deleting the account removes every cloud document of
/// that uid for good. Local songs/folders are never deleted.
library;

/// How far an interrupted account deletion got. Stored in `sync_meta`
/// (`account_deletion_state`) so it survives an app restart. While any
/// stage is recorded, no sync of any kind may run on this device.
enum AccountDeletionStage {
  /// Re-authenticated; creating the cloud deletion block
  /// (`accountDeletionBlocks/{uid}`). No user document touched yet.
  blocking,

  /// The block exists; deleting the cloud documents (may be partial).
  cloudDeleting,

  /// Every cloud document of the uid was deleted; the Firebase Auth user
  /// still exists.
  cloudDeleted,

  /// The Firebase Auth user is gone too; only the local cleanup (unbinding)
  /// is left. Safe to finish without network.
  authDeleted;

  String get storedName => switch (this) {
    blocking => 'blocking',
    cloudDeleting => 'cloud_deleting',
    cloudDeleted => 'cloud_deleted',
    authDeleted => 'auth_deleted',
  };

  static AccountDeletionStage? parse(String? v) => switch (v) {
    'blocking' => blocking,
    'cloud_deleting' => cloudDeleting,
    'cloud_deleted' => cloudDeleted,
    'auth_deleted' => authDeleted,
    _ => null,
  };
}

/// A started, not yet finished account deletion recorded on this device.
class PendingAccountDeletion {
  final String uid;
  final AccountDeletionStage stage;

  /// Cloud documents deleted so far (all attempts), for display/logs.
  final int deletedDocs;

  const PendingAccountDeletion({
    required this.uid,
    required this.stage,
    this.deletedDocs = 0,
  });
}

/// Local (SQLite) side of account deletion. Implemented by
/// `SqliteLocalSyncStore`.
abstract class AccountDeletionStore {
  Future<PendingAccountDeletion?> readPendingAccountDeletion();

  /// Records that deleting [uid]'s account has started (stage
  /// [AccountDeletionStage.blocking]); from now on every sync is
  /// refused. Keeps a later stage already recorded for the same uid.
  /// Throws [StateError] (writing nothing) if the device is bound to a
  /// different account or another uid's deletion is pending.
  Future<void> markAccountDeletionStarted(String uid);

  /// Raises the recorded stage (never lowers it) and/or the deleted-doc
  /// count, only for the pending deletion of [uid].
  Future<void> recordAccountDeletionProgress(
    String uid, {
    AccountDeletionStage? stage,
    int? deletedDocs,
  });

  /// Forgets a deletion that never reached the cloud: only while still at
  /// [AccountDeletionStage.blocking] for [uid] (the caller has confirmed
  /// the block does not exist). Throws [StateError] otherwise.
  Future<void> cancelAccountDeletion(String uid);

  /// Final local step, in ONE transaction, only for the pending deletion
  /// of [uid]: removes the cloud binding and sync bookkeeping
  /// (`account_uid`, email hint, pull cursors, last sync time, initial
  /// sync state) and the deletion marker, and marks every song, folder,
  /// membership and tombstone as "needs upload" so a later first
  /// connection (any account) backs everything up again. Songs, folders,
  /// memberships, tombstones and sync ids are kept as they are.
  Future<void> finishAccountDeletion(String uid);
}

/// Hard-deletes a user's cloud data. The Firestore implementation lives in
/// `sync/android/firestore_account_data_eraser.dart`.
abstract class CloudAccountDataEraser {
  /// Most deletes per batch commit (Firestore allows 500).
  static const maxBatchDeletes = 400;

  /// Top-level collection of deletion blocks: `accountDeletionBlocks/{uid}`
  /// with a single field `deletedAt` (server time). While it exists, the
  /// security rules refuse every create/update under `users/{uid}` (a
  /// stale device of the deleted account can't re-create anything); hard
  /// deletes stay allowed. Never removed by the app.
  static const blocksCollection = 'accountDeletionBlocks';

  /// Makes sure `accountDeletionBlocks/{uid}` exists: creates it (only
  /// `deletedAt` = server time) if missing, then reads it back from the
  /// server. Returns only once the block is confirmed; throws
  /// `CloudSyncBackendException` otherwise. Never overwrites a block.
  Future<void> ensureDeletionBlock(String uid);

  /// Whether `accountDeletionBlocks/{uid}` exists (server read). Throws
  /// `CloudSyncBackendException` if it can't be told.
  Future<bool> deletionBlockExists(String uid);

  /// Deletes every document under `users/{uid}/songs`, `folders` and
  /// `folderSongs`, at most [maxBatchDeletes] per commit, and only under
  /// [uid]. Idempotent: running it again after a failure deletes whatever
  /// is left (0 when nothing is). Returns the number deleted by this call;
  /// [onBatchCommitted] gets the running total after each committed batch.
  /// Throws `CloudSyncBackendException`.
  Future<int> deleteAllUserData(
    String uid, {
    void Function(int deletedSoFar)? onBatchCommitted,
  });
}
