import '../models/folder.dart';
import '../models/song.dart';

/// Writes changes that came *from the cloud* into local storage.
///
/// This is the only path that stores rows as clean (`sync_dirty = 0`). The
/// regular [SongRepository] / [FolderRepository] methods are for user edits
/// and always store rows as dirty (`sync_dirty = 1`). The path decides,
/// not any flag, so a user edit made while a cloud batch is being applied
/// still counts as a local change that must be uploaded.
///
/// Policy that belongs to the caller (the future sync engine), not here:
/// deciding *whether* a remote change should win over a dirty local row.
/// The one rule enforced here is that a song/folder deleted on this device
/// is never brought back by a cloud upsert (deletion always wins).
///
/// No network code. Android (SQLite) only for now.
abstract class CloudApplyStore {
  /// Runs [body] in a single local transaction. If [body] throws, nothing
  /// it wrote is kept.
  ///
  /// Also marks `sync_apply_in_progress` in `sync_meta`, committed together
  /// with the batch. The mark stays across batches (and app restarts) until
  /// [finishApply] is called, so a multi-batch apply that is interrupted
  /// half way never triggers cleanup of rows that are waiting for the rest.
  Future<T> applyBatch<T>(Future<T> Function(CloudApplyWriter writer) body);

  /// Clears the `sync_apply_in_progress` mark. Call once, after every batch
  /// of a cloud apply has been committed.
  Future<void> finishApply();

  Future<bool> isApplyInProgress();
}

/// Result of applying one remote row.
enum CloudApplyOutcome {
  inserted,
  updated,

  /// The song/folder has a deletion record on this device; deletion wins,
  /// so it was not written.
  skippedDeleted,

  /// A folder membership whose song or folder isn't present locally.
  skippedMissingParent,
}

/// Write operations available inside [CloudApplyStore.applyBatch]. Every
/// row written here is stored with `sync_dirty = 0`, and `sync_id` values
/// are taken from the cloud data and never changed on existing rows.
abstract class CloudApplyWriter {
  /// Inserts or updates the song identified by [song]'s `syncId` (which is
  /// required). [song]'s local `id` is ignored. [updatedAtMs] is the
  /// cloud's change time and becomes `sync_updated_at_ms`.
  Future<CloudApplyOutcome> upsertSong(Song song, {required int updatedAtMs});

  /// Same as [upsertSong], for folders.
  Future<CloudApplyOutcome> upsertFolder(
    Folder folder, {
    required int updatedAtMs,
  });

  /// Makes the song a member of the folder. Both must already exist
  /// locally. Clears any removal record for this membership.
  Future<CloudApplyOutcome> upsertFolderSong({
    required String folderSyncId,
    required String songSyncId,
    required DateTime addedAt,
    required int updatedAtMs,
  });

  /// Deletes the song (and its folder memberships) and records the
  /// deletion as already synced. Recorded even if the song isn't present
  /// locally, so a stale copy arriving later is skipped.
  Future<void> applySongDeletion(String syncId, {required int deletedAtMs});

  /// Deletes the folder (and its memberships; never the songs) and records
  /// the deletion as already synced.
  Future<void> applyFolderDeletion(String syncId, {required int deletedAtMs});

  /// Removes the song from the folder and records the removal as synced.
  Future<void> applyFolderSongRemoval({
    required String folderSyncId,
    required String songSyncId,
    required int deletedAtMs,
  });
}
