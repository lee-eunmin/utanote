import 'dart:convert';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../../sync/account_data_deletion.dart';
import '../../sync/local_sync_store.dart';
import '../../sync/sync_records.dart';
import '../cloud_apply.dart';
import '../sync_id.dart';
import 'sqlite_cloud_apply.dart';
import 'sqlite_pre_cloud_backup.dart';
import 'sqlite_schema.dart';

/// SQLite side of the initial cloud sync. Reads raw rows (stored strings
/// are passed on verbatim, never re-formatted), and writes only through
/// the clean cloud-apply path, the guarded dirty-clear below, and
/// `sync_meta`. No schema change.
class SqliteLocalSyncStore implements LocalSyncStore, AccountDeletionStore {
  final Database _db;
  final String _databasePath;

  SqliteLocalSyncStore(this._db, this._databasePath);

  @override
  Future<LocalSyncSnapshot> readSnapshot() => readLocalSyncSnapshot(_db);

  @override
  Future<InitialSyncMeta> readMeta() async {
    Future<String?> read(String key) async {
      final v = await readSyncMeta(_db, key);
      return (v == null || v.isEmpty) ? null : v;
    }

    return InitialSyncMeta(
      accountUid: await read(SyncMetaKeys.accountUid),
      state: await read(SyncMetaKeys.initialSyncState),
      mode: await read(SyncMetaKeys.initialSyncMode),
      uid: await read(SyncMetaKeys.initialSyncUid),
      lastSuccessfulSyncAtMs:
          int.tryParse(await read(SyncMetaKeys.lastSuccessfulSyncAtMs) ?? ''),
      accountDeletionPending:
          await read(SyncMetaKeys.accountDeletionState) != null,
    );
  }

  @override
  Future<PreCloudBackupResult> ensurePreCloudBackup() async {
    final attempt = await createPreCloudSyncBackupIfMissing(
      db: _db,
      databasePath: _databasePath,
    );
    switch (attempt.outcome) {
      case PreCloudBackupOutcome.failed:
        return PreCloudBackupResult(
          PreCloudBackupStatus.failed,
          error: attempt.error,
        );
      case PreCloudBackupOutcome.created:
      case PreCloudBackupOutcome.alreadyExists:
        try {
          await writeSyncMetaIfMissing(
            _db,
            SyncMetaKeys.preCloudSyncBackupFile,
            p.basename(attempt.backupPath),
          );
          await writeSyncMetaIfMissing(
            _db,
            SyncMetaKeys.preCloudSyncBackupCreatedAtMs,
            nowUtcMs().toString(),
          );
        } catch (_) {
          // Metadata only; the backup file itself is what matters.
        }
        return PreCloudBackupResult(
          attempt.outcome == PreCloudBackupOutcome.created
              ? PreCloudBackupStatus.created
              : PreCloudBackupStatus.alreadyExists,
        );
    }
  }

  @override
  Future<void> markInitialSyncStarted(String uid, String mode) async {
    await _db.transaction((txn) async {
      await _requireNoAccountDeletion(txn);
      await writeSyncMeta(txn, SyncMetaKeys.initialSyncState,
          InitialSyncState.inProgress);
      await writeSyncMeta(txn, SyncMetaKeys.initialSyncMode, mode);
      await writeSyncMeta(txn, SyncMetaKeys.initialSyncUid, uid);
    });
  }

  @override
  Future<void> markInitialSyncFailed(
    String uid,
    String mode,
    String error,
  ) async {
    await _db.transaction((txn) async {
      // Never downgrade a completed binding.
      if (await readSyncMeta(txn, SyncMetaKeys.initialSyncState) ==
          InitialSyncState.done) {
        return;
      }
      await writeSyncMeta(
          txn, SyncMetaKeys.initialSyncState, InitialSyncState.failed);
      await writeSyncMeta(txn, SyncMetaKeys.initialSyncMode, mode);
      await writeSyncMeta(txn, SyncMetaKeys.initialSyncUid, uid);
      await writeSyncMeta(
        txn,
        SyncMetaKeys.initialSyncError,
        error.length > 500 ? error.substring(0, 500) : error,
      );
    });
  }

  @override
  Future<void> commitInitialSync({
    required String uid,
    required String? email,
    required String mode,
    required List<SyncDirtyToken> cleanTokens,
    required Future<void> Function(
      LocalSyncSnapshot fresh,
      CloudApplyWriter writer,
    ) apply,
  }) async {
    await _db.transaction((txn) async {
      await _requireNoAccountDeletion(txn);
      final existing = await readSyncMeta(txn, SyncMetaKeys.accountUid);
      if (existing != null && existing.isNotEmpty && existing != uid) {
        throw StateError('database is already bound to another account');
      }
      await writeSyncMetaIfMissing(
        txn,
        SyncMetaKeys.syncApplyInProgress,
        nowUtcMs().toString(),
      );
      final fresh = await readLocalSyncSnapshot(txn);
      await apply(fresh, sqliteCloudApplyWriter(txn));
      await clearSyncDirtyIfUnchangedIn(txn, cleanTokens);

      final now = nowUtcMs().toString();
      await writeSyncMeta(txn, SyncMetaKeys.accountUid, uid);
      if (email != null && email.isNotEmpty) {
        await writeSyncMeta(txn, SyncMetaKeys.accountEmailHint, email);
      }
      await writeSyncMeta(
          txn, SyncMetaKeys.initialSyncState, InitialSyncState.done);
      await writeSyncMeta(txn, SyncMetaKeys.initialSyncMode, mode);
      await writeSyncMeta(txn, SyncMetaKeys.initialSyncUid, uid);
      await writeSyncMeta(txn, SyncMetaKeys.lastSuccessfulSyncAtMs, now);
      await txn.delete(
        'sync_meta',
        where: 'key = ?',
        whereArgs: [SyncMetaKeys.initialSyncError],
      );
    });
    // Same contract as CloudApplyStore.finishApply: cleared only once the
    // whole apply has committed.
    await _db.delete(
      'sync_meta',
      where: 'key = ?',
      whereArgs: [SyncMetaKeys.syncApplyInProgress],
    );
  }

  @override
  Future<int> clearSyncDirtyIfUnchanged(List<SyncDirtyToken> tokens) =>
      _db.transaction((txn) => clearSyncDirtyIfUnchangedIn(txn, tokens));

  // --- Phase B-4A: manual incremental sync ---------------------------------

  @override
  Future<PullCursors> readPullCursors() async {
    Future<int?> read(String key) async =>
        int.tryParse(await readSyncMeta(_db, key) ?? '');
    return PullCursors(
      songsMs: await read(SyncMetaKeys.pullCursorSongsMs),
      foldersMs: await read(SyncMetaKeys.pullCursorFoldersMs),
      folderSongsMs: await read(SyncMetaKeys.pullCursorFolderSongsMs),
    );
  }

  @override
  Future<int> applyIncremental({
    required String uid,
    required Future<IncrementalApplyOutcome> Function(
      LocalSyncSnapshot fresh,
      CloudApplyWriter writer,
    ) apply,
  }) async {
    final changes = await _db.transaction((txn) async {
      await _requireBound(txn, uid);
      await writeSyncMetaIfMissing(
        txn,
        SyncMetaKeys.syncApplyInProgress,
        nowUtcMs().toString(),
      );
      final fresh = await readLocalSyncSnapshot(txn);
      final outcome = await apply(fresh, sqliteCloudApplyWriter(txn));
      await clearSyncDirtyIfUnchangedIn(txn, outcome.cleanTokens);
      await markSyncDirtyIn(txn, outcome.markDirty);
      return outcome.localChanges;
    });
    await _db.delete(
      'sync_meta',
      where: 'key = ?',
      whereArgs: [SyncMetaKeys.syncApplyInProgress],
    );
    return changes;
  }

  @override
  Future<void> commitIncrementalSuccess({
    required String uid,
    required PullCursors cursors,
    required int syncedAtMs,
  }) async {
    await _db.transaction((txn) async {
      await _requireBound(txn, uid);
      Future<void> raise(String key, int? value) async {
        if (value == null) return;
        final current = int.tryParse(await readSyncMeta(txn, key) ?? '');
        if (current != null && current >= value) return;
        await writeSyncMeta(txn, key, value.toString());
      }

      await raise(SyncMetaKeys.pullCursorSongsMs, cursors.songsMs);
      await raise(SyncMetaKeys.pullCursorFoldersMs, cursors.foldersMs);
      await raise(SyncMetaKeys.pullCursorFolderSongsMs, cursors.folderSongsMs);
      await writeSyncMeta(
        txn,
        SyncMetaKeys.lastSuccessfulSyncAtMs,
        syncedAtMs.toString(),
      );
    });
  }

  // --- Phase B-5: account deletion -------------------------------------------

  @override
  Future<PendingAccountDeletion?> readPendingAccountDeletion() =>
      _readPendingDeletion(_db);

  @override
  Future<void> markAccountDeletionStarted(String uid) async {
    if (uid.isEmpty) throw ArgumentError('empty uid');
    await _db.transaction((txn) async {
      final bound = await readSyncMeta(txn, SyncMetaKeys.accountUid);
      if (bound != null && bound.isNotEmpty && bound != uid) {
        throw StateError('database is bound to another account');
      }
      final pending = await _readPendingDeletion(txn);
      if (pending != null) {
        if (pending.uid != uid) {
          throw StateError('another account deletion is pending');
        }
        return; // resuming: keep the stage reached so far
      }
      await writeSyncMeta(txn, SyncMetaKeys.accountDeletionUid, uid);
      await writeSyncMeta(
        txn,
        SyncMetaKeys.accountDeletionState,
        AccountDeletionStage.blocking.storedName,
      );
      await writeSyncMeta(
        txn,
        SyncMetaKeys.accountDeletionStartedAtMs,
        nowUtcMs().toString(),
      );
      await writeSyncMeta(txn, SyncMetaKeys.accountDeletionDeletedDocs, '0');
    });
  }

  @override
  Future<void> recordAccountDeletionProgress(
    String uid, {
    AccountDeletionStage? stage,
    int? deletedDocs,
  }) async {
    await _db.transaction((txn) async {
      final pending = await _readPendingDeletion(txn);
      if (pending == null || pending.uid != uid) return;
      if (stage != null && stage.index > pending.stage.index) {
        await writeSyncMeta(
          txn,
          SyncMetaKeys.accountDeletionState,
          stage.storedName,
        );
      }
      if (deletedDocs != null && deletedDocs > pending.deletedDocs) {
        await writeSyncMeta(
          txn,
          SyncMetaKeys.accountDeletionDeletedDocs,
          deletedDocs.toString(),
        );
      }
    });
  }

  @override
  Future<void> cancelAccountDeletion(String uid) async {
    await _db.transaction((txn) async {
      final pending = await _readPendingDeletion(txn);
      if (pending == null ||
          pending.uid != uid ||
          pending.stage != AccountDeletionStage.blocking) {
        throw StateError('deletion can no longer be cancelled');
      }
      await _deleteMetaKeys(txn, SyncMetaKeys.accountDeletionKeys);
    });
  }

  @override
  Future<void> finishAccountDeletion(String uid) async {
    await _db.transaction((txn) async {
      final pending = await _readPendingDeletion(txn);
      if (pending == null || pending.uid != uid) {
        throw StateError('no pending deletion for this account');
      }
      final bound = await readSyncMeta(txn, SyncMetaKeys.accountUid);
      if (bound != null && bound.isNotEmpty && bound != uid) {
        throw StateError('database is bound to another account');
      }
      await _resetCloudBindingIn(txn);
    });
  }

  // --- Phase B-5.1: release a stale binding (same Google account) ----------

  /// The email recorded with the binding (`account_email_hint`), or null.
  Future<String?> readBoundAccountEmailHint() async {
    final v = await readSyncMeta(_db, SyncMetaKeys.accountEmailHint);
    return (v == null || v.isEmpty) ? null : v;
  }

  /// Explicit, user-approved release of this device's binding to an
  /// earlier cloud account (e.g. the same Google account deleted and
  /// re-created, which gets a new uid). Local only, ONE transaction: only
  /// while the device is still bound to [expectedBoundUid]; removes the
  /// binding/sync bookkeeping and any deletion marker, marks every row
  /// "needs upload". Songs, folders, memberships, tombstones and sync ids
  /// are kept; nothing is uploaded or merged.
  Future<void> releasePreviousBinding({
    required String expectedBoundUid,
  }) async {
    await _db.transaction((txn) async {
      final bound = await readSyncMeta(txn, SyncMetaKeys.accountUid);
      if (bound == null || bound.isEmpty || bound != expectedBoundUid) {
        throw StateError('binding changed');
      }
      await _resetCloudBindingIn(txn);
    });
  }

  /// Removes the binding/sync bookkeeping and the deletion marker and marks
  /// every row "needs upload" (for whatever account comes next). Only the
  /// flag changes: data, sync ids and timestamps stay as they are. Backup
  /// files and their meta keys are kept.
  static Future<void> _resetCloudBindingIn(DatabaseExecutor txn) async {
    await _deleteMetaKeys(txn, [
      ...SyncMetaKeys.cloudBindingKeys,
      ...SyncMetaKeys.accountDeletionKeys,
    ]);
    for (final table in const [
      'songs',
      'folders',
      'folder_songs',
      'sync_tombstones',
    ]) {
      await txn.rawUpdate(
        'UPDATE $table SET sync_dirty = ${SyncDirty.dirty} '
        'WHERE sync_dirty IS NOT ${SyncDirty.dirty}',
      );
    }
  }

  static Future<void> _deleteMetaKeys(
    DatabaseExecutor txn,
    List<String> keys,
  ) =>
      txn.delete(
        'sync_meta',
        where: 'key IN (${List.filled(keys.length, '?').join(',')})',
        whereArgs: keys,
      );

  static Future<PendingAccountDeletion?> _readPendingDeletion(
    DatabaseExecutor db,
  ) async {
    final stage = AccountDeletionStage.parse(
      await readSyncMeta(db, SyncMetaKeys.accountDeletionState),
    );
    final uid = await readSyncMeta(db, SyncMetaKeys.accountDeletionUid);
    if (stage == null) {
      // An unknown/garbled state still blocks sync (see
      // _requireNoAccountDeletion), reported as the earliest stage.
      final raw = await readSyncMeta(db, SyncMetaKeys.accountDeletionState);
      if (raw == null || raw.isEmpty || uid == null || uid.isEmpty) {
        return null;
      }
      return PendingAccountDeletion(
        uid: uid,
        stage: AccountDeletionStage.cloudDeleting,
      ); // not "blocking": an unknown state is never cancellable
    }
    if (uid == null || uid.isEmpty) return null;
    return PendingAccountDeletion(
      uid: uid,
      stage: stage,
      deletedDocs:
          int.tryParse(
            await readSyncMeta(db, SyncMetaKeys.accountDeletionDeletedDocs) ??
                '',
          ) ??
          0,
    );
  }

  /// Every sync entry point refuses to run while an account deletion is
  /// pending, so nothing can be re-uploaded into a cloud being deleted.
  static Future<void> _requireNoAccountDeletion(DatabaseExecutor txn) async {
    final state = await readSyncMeta(txn, SyncMetaKeys.accountDeletionState);
    if (state != null && state.isNotEmpty) {
      throw const SyncBlockedByAccountDeletion();
    }
  }

  static Future<void> _requireBound(DatabaseExecutor txn, String uid) async {
    await _requireNoAccountDeletion(txn);
    final bound = await readSyncMeta(txn, SyncMetaKeys.accountUid);
    if (bound == null || bound.isEmpty || bound != uid) {
      throw const SyncAccountMismatch();
    }
  }
}

/// Sets `sync_dirty = 1` on each token's row (version is ignored): the
/// local version won a comparison and must be uploaded.
Future<void> markSyncDirtyIn(
  DatabaseExecutor db,
  List<SyncDirtyToken> tokens,
) async {
  for (final t in tokens) {
    switch (t.kind) {
      case SyncDirtyTokenKind.song:
        await db.rawUpdate(
          'UPDATE songs SET sync_dirty = ${SyncDirty.dirty} WHERE sync_id = ?',
          [t.syncId],
        );
      case SyncDirtyTokenKind.folder:
        await db.rawUpdate(
          'UPDATE folders SET sync_dirty = ${SyncDirty.dirty} WHERE sync_id = ?',
          [t.syncId],
        );
      case SyncDirtyTokenKind.membership:
        await db.rawUpdate(
          'UPDATE folder_songs SET sync_dirty = ${SyncDirty.dirty} '
          'WHERE folder_id = (SELECT id FROM folders WHERE sync_id = ?) '
          'AND song_id = (SELECT id FROM songs WHERE sync_id = ?)',
          [t.syncId, t.relatedSyncId],
        );
      case SyncDirtyTokenKind.tombstone:
        await db.rawUpdate(
          'UPDATE sync_tombstones SET sync_dirty = ${SyncDirty.dirty} '
          'WHERE entity_type = ? AND sync_id = ? AND related_sync_id = ?',
          [t.entityType, t.syncId, t.relatedSyncId],
        );
    }
  }
}

/// Sets `sync_dirty = 0` on each token's row only while the row still has
/// the version the token recorded (`IS` so a NULL legacy version matches
/// NULL). A row edited, re-deleted or re-added since the snapshot no
/// longer matches and stays dirty. Returns the number of rows cleared.
Future<int> clearSyncDirtyIfUnchangedIn(
  DatabaseExecutor db,
  List<SyncDirtyToken> tokens,
) async {
  var cleared = 0;
  for (final t in tokens) {
    switch (t.kind) {
      case SyncDirtyTokenKind.song:
        cleared += await db.rawUpdate(
          'UPDATE songs SET sync_dirty = ${SyncDirty.clean} '
          'WHERE sync_id = ? AND sync_updated_at_ms IS ? AND sync_dirty != ${SyncDirty.clean}',
          [t.syncId, t.expectedVersion],
        );
      case SyncDirtyTokenKind.folder:
        cleared += await db.rawUpdate(
          'UPDATE folders SET sync_dirty = ${SyncDirty.clean} '
          'WHERE sync_id = ? AND sync_updated_at_ms IS ? AND sync_dirty != ${SyncDirty.clean}',
          [t.syncId, t.expectedVersion],
        );
      case SyncDirtyTokenKind.membership:
        cleared += await db.rawUpdate(
          'UPDATE folder_songs SET sync_dirty = ${SyncDirty.clean} '
          'WHERE folder_id = (SELECT id FROM folders WHERE sync_id = ?) '
          'AND song_id = (SELECT id FROM songs WHERE sync_id = ?) '
          'AND sync_updated_at_ms IS ? AND sync_dirty != ${SyncDirty.clean}',
          [t.syncId, t.relatedSyncId, t.expectedVersion],
        );
      case SyncDirtyTokenKind.tombstone:
        cleared += await db.rawUpdate(
          'UPDATE sync_tombstones SET sync_dirty = ${SyncDirty.clean} '
          'WHERE entity_type = ? AND sync_id = ? AND related_sync_id = ? '
          'AND deleted_at_ms IS ? AND sync_dirty != ${SyncDirty.clean}',
          [t.entityType, t.syncId, t.relatedSyncId, t.expectedVersion],
        );
    }
  }
  return cleared;
}

/// Reads every row the initial sync compares. Rows without a sync id
/// (impossible after migration) and memberships whose song or folder is
/// missing (legacy orphans) are left out.
Future<LocalSyncSnapshot> readLocalSyncSnapshot(DatabaseExecutor db) async {
  final songs = <String, LocalSongRow>{};
  for (final r in await db.query('songs')) {
    final syncId = r['sync_id'] as String?;
    if (!hasSyncId(syncId)) continue;
    songs[syncId!] = LocalSongRow(
      syncId: syncId,
      data: SongData(
        karaokeType: r['karaoke_type'] as String,
        songNumber: r['song_number'] as String,
        title: r['title'] as String,
        artist: r['artist'] as String?,
        keyType: r['key_type'] as String?,
        keyOffset: (r['key_offset'] as int?) ?? 0,
        difficulty: r['difficulty'] as String?,
        practiceStatus: r['practice_status'] as String?,
        memo: r['memo'] as String?,
        favorite: (r['favorite'] as int?) == 1,
        searchAliases: _decodeAliases(r['search_aliases'] as String?),
        createdAt: r['created_at'] as String,
        updatedAt: r['updated_at'] as String,
      ),
      syncUpdatedAtMs: r['sync_updated_at_ms'] as int?,
      dirty: (r['sync_dirty'] as int?) != SyncDirty.clean,
    );
  }

  final folders = <String, LocalFolderRow>{};
  for (final r in await db.query('folders')) {
    final syncId = r['sync_id'] as String?;
    if (!hasSyncId(syncId)) continue;
    folders[syncId!] = LocalFolderRow(
      syncId: syncId,
      data: FolderData(
        name: r['name'] as String,
        createdAt: r['created_at'] as String,
        updatedAt: r['updated_at'] as String,
      ),
      syncUpdatedAtMs: r['sync_updated_at_ms'] as int?,
      dirty: (r['sync_dirty'] as int?) != SyncDirty.clean,
    );
  }

  final memberships = <String, LocalMembershipRow>{};
  for (final r in await db.rawQuery('''
    SELECT f.sync_id AS folder_sync_id, s.sync_id AS song_sync_id,
           fs.added_at, fs.sync_updated_at_ms, fs.sync_dirty, fs.revision
    FROM folder_songs fs
    INNER JOIN folders f ON f.id = fs.folder_id
    INNER JOIN songs s ON s.id = fs.song_id
  ''')) {
    final f = r['folder_sync_id'] as String?;
    final s = r['song_sync_id'] as String?;
    if (!hasSyncId(f) || !hasSyncId(s)) continue;
    final row = LocalMembershipRow(
      folderSyncId: f!,
      songSyncId: s!,
      addedAt: r['added_at'] as String,
      syncUpdatedAtMs: r['sync_updated_at_ms'] as int?,
      dirty: (r['sync_dirty'] as int?) != SyncDirty.clean,
      revision: (r['revision'] as int?) ?? kFirstMembershipRevision,
    );
    memberships[row.key] = row;
  }

  final songTombstones = <String, LocalTombstone>{};
  final folderTombstones = <String, LocalTombstone>{};
  final membershipTombstones = <String, LocalTombstone>{};
  for (final r in await db.query('sync_tombstones')) {
    final t = LocalTombstone(
      entityType: r['entity_type'] as String,
      syncId: r['sync_id'] as String,
      relatedSyncId: (r['related_sync_id'] as String?) ?? '',
      deletedAtMs: r['deleted_at_ms'] as int,
      dirty: (r['sync_dirty'] as int?) != SyncDirty.clean,
      revision: r['revision'] as int?,
    );
    if (!hasSyncId(t.syncId)) continue;
    switch (t.entityType) {
      case TombstoneEntity.song:
        songTombstones[t.syncId] = t;
      case TombstoneEntity.folder:
        folderTombstones[t.syncId] = t;
      case TombstoneEntity.folderSong:
        if (!hasSyncId(t.relatedSyncId)) continue;
        membershipTombstones[membershipDocId(t.syncId, t.relatedSyncId)] = t;
    }
  }

  return LocalSyncSnapshot(
    songs: songs,
    folders: folders,
    memberships: memberships,
    songTombstones: songTombstones,
    folderTombstones: folderTombstones,
    membershipTombstones: membershipTombstones,
  );
}

List<String> _decodeAliases(String? raw) {
  if (raw == null || raw.isEmpty) return const [];
  try {
    final decoded = jsonDecode(raw);
    if (decoded is List) return decoded.map((e) => e.toString()).toList();
  } catch (_) {}
  return const [];
}
