/// Local-database side of the initial cloud sync. Implemented by SQLite on
/// Android (`storage/android/sqlite_sync_store.dart`). Pure interface: no
/// SQLite or Firestore types.
library;

import '../storage/cloud_apply.dart';
import 'sync_records.dart';

enum SyncDirtyTokenKind { song, folder, membership, tombstone }

/// "This row was uploaded (or found identical in the cloud) as it was at
/// snapshot time." Clearing `sync_dirty` with a token only succeeds if the
/// row still has exactly the version recorded here, so a user edit made
/// while the upload was in flight stays dirty.
///
/// Version = `sync_updated_at_ms` for songs/folders/memberships (NULL for
/// untouched legacy rows; any edit sets it), `deleted_at_ms` for tombstones.
class SyncDirtyToken {
  final SyncDirtyTokenKind kind;

  /// Song/folder sync id; folder sync id for memberships; tombstone
  /// `sync_id` for tombstones.
  final String syncId;

  /// Song sync id for memberships; tombstone `related_sync_id`; else ''.
  final String relatedSyncId;

  /// Tombstone `entity_type`; '' otherwise.
  final String entityType;

  final int? expectedVersion;

  const SyncDirtyToken._(
    this.kind,
    this.syncId,
    this.expectedVersion, {
    this.relatedSyncId = '',
    this.entityType = '',
  });

  factory SyncDirtyToken.song(String syncId, int? syncUpdatedAtMs) =>
      SyncDirtyToken._(SyncDirtyTokenKind.song, syncId, syncUpdatedAtMs);

  factory SyncDirtyToken.folder(String syncId, int? syncUpdatedAtMs) =>
      SyncDirtyToken._(SyncDirtyTokenKind.folder, syncId, syncUpdatedAtMs);

  factory SyncDirtyToken.membership(
    String folderSyncId,
    String songSyncId,
    int? syncUpdatedAtMs,
  ) =>
      SyncDirtyToken._(
        SyncDirtyTokenKind.membership,
        folderSyncId,
        syncUpdatedAtMs,
        relatedSyncId: songSyncId,
      );

  factory SyncDirtyToken.tombstone(LocalTombstone t) => SyncDirtyToken._(
        SyncDirtyTokenKind.tombstone,
        t.syncId,
        t.deletedAtMs,
        relatedSyncId: t.relatedSyncId,
        entityType: t.entityType,
      );
}

/// Values of `sync_meta.initial_sync_state`.
abstract final class InitialSyncState {
  static const inProgress = 'in_progress';
  static const failed = 'failed';
  static const done = 'done';
}

/// Values of `sync_meta.initial_sync_mode`.
abstract final class InitialSyncModeName {
  static const upload = 'upload';
  static const restore = 'restore';
  static const merge = 'merge';
  static const bindOnly = 'bind_only';
}

class InitialSyncMeta {
  final String? accountUid;
  final String? state;
  final String? mode;

  /// The account an unfinished initial sync was started for.
  final String? uid;

  const InitialSyncMeta({this.accountUid, this.state, this.mode, this.uid});
}

enum PreCloudBackupStatus { created, alreadyExists, failed }

class PreCloudBackupResult {
  final PreCloudBackupStatus status;
  final Object? error;

  const PreCloudBackupResult(this.status, {this.error});

  bool get ok => status != PreCloudBackupStatus.failed;
}

abstract class LocalSyncStore {
  Future<LocalSyncSnapshot> readSnapshot();

  Future<InitialSyncMeta> readMeta();

  /// Makes `songbook.pre_cloud_sync_v4.backup.db` if it doesn't exist yet
  /// (never overwrites). Never throws; check [PreCloudBackupResult.ok].
  Future<PreCloudBackupResult> ensurePreCloudBackup();

  /// Records that an initial sync for [uid] in [mode] has started, so an
  /// interrupted run can be resumed. Never writes `account_uid`.
  Future<void> markInitialSyncStarted(String uid, String mode);

  /// Records a failed attempt (best effort). Never writes `account_uid`.
  Future<void> markInitialSyncFailed(String uid, String mode, String error);

  /// Final step of a successful initial sync, in ONE local transaction:
  /// re-reads the local data, lets [apply] write the cloud's winning rows
  /// through the clean (cloud-apply) path, clears `sync_dirty` for
  /// [cleanTokens] whose rows are unchanged, and binds the database to
  /// [uid] (`account_uid`, `account_email_hint`, state = done). If anything
  /// throws, none of it is kept.
  Future<void> commitInitialSync({
    required String uid,
    required String? email,
    required String mode,
    required List<SyncDirtyToken> cleanTokens,
    required Future<void> Function(
      LocalSyncSnapshot fresh,
      CloudApplyWriter writer,
    ) apply,
  });

  /// Sets `sync_dirty = 0` for each token's row only if its version still
  /// matches the token. Returns how many rows were cleared.
  Future<int> clearSyncDirtyIfUnchanged(List<SyncDirtyToken> tokens);
}
