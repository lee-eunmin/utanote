import 'package:sqflite/sqflite.dart';

import '../sync_id.dart';

/// Schema for the Android `songbook.db`. Additive-only — see CLAUDE.md.
///
/// History:
/// - 0: legacy FlutterFlow app. Tables exist but `user_version` was never
///   set, so sqflite runs `onCreate` (not `onUpgrade`) against real data.
/// - 2: `songs.search_aliases`.
/// - 3: cloud-sync readiness (Phase A): `sync_id` / `sync_updated_at_ms`
///   columns, `sync_tombstones`, `sync_meta`. No account or network code.
/// - 4: change tracking (Phase B-1): `sync_dirty` on `songs`, `folders`,
///   `folder_songs` and `sync_tombstones`. Still no account or network code.
/// - 5: folder-membership revisions (Phase B-4A): `folder_songs.revision`
///   and `sync_tombstones.revision` (meaningful for `folder_song` rows only).
const int kSongbookDatabaseVersion = 5;

/// Revision a membership gets when its first state is recorded: the first
/// add. Pre-v5 live memberships are backfilled with it.
const int kFirstMembershipRevision = 1;

/// Revision assumed for a pre-v5 membership removal (a `folder_song`
/// tombstone without a revision): at least one add (1) followed by the
/// removal (2). Always above [kFirstMembershipRevision], so for legacy data
/// a removal still beats a live membership, exactly as before v5.
const int kLegacyMembershipRemovalRevision = 2;

/// Column DDL for `sync_dirty`: 1 = changed locally and not yet confirmed
/// in the cloud, 0 = matches what the cloud has. DEFAULT 1 means every row
/// that exists when the column is added (all pre-v4 data) starts out as
/// "needs upload", which is exactly what a first cloud upload must send.
const String kSyncDirtyColumnDdl = 'INTEGER NOT NULL DEFAULT 1';

/// Values of the `sync_dirty` column. Which one a write uses is decided
/// only by the code path doing the write: local repository writes always
/// use [dirty], `SqliteCloudApply` always uses [clean]. It is never derived
/// from [SyncMetaKeys.syncApplyInProgress], so a user edit made while a
/// cloud batch is mid-apply is still recorded as dirty.
abstract final class SyncDirty {
  static const int clean = 0;
  static const int dirty = 1;
}

/// Entity types recorded in `sync_tombstones.entity_type`.
abstract final class TombstoneEntity {
  static const song = 'song';
  static const folder = 'folder';

  /// A song removed from a folder. `sync_id` = folder's sync id,
  /// `related_sync_id` = song's sync id.
  static const folderSong = 'folder_song';
}

/// Keys in the `sync_meta` key/value table. Only the backup and cleanup
/// keys are written in Phase A; the account/sync keys are reserved for the
/// future sync layer and stay absent until then.
abstract final class SyncMetaKeys {
  /// Cloud account (e.g. auth uid) this local database is bound to. Absent
  /// = not linked to any account.
  static const accountUid = 'account_uid';

  /// UTC epoch ms of the last fully successful sync. Absent = never synced.
  static const lastSuccessfulSyncAtMs = 'last_successful_sync_at_ms';

  /// Set by the future sync layer while it is applying a remote batch, and
  /// cleared when the batch is fully applied. While present, nothing that
  /// deletes "dangling" rows (see [runLegacyOrphanCleanupOnce]) may run,
  /// because a half-applied batch can legitimately contain folder_songs
  /// rows whose songs have not arrived yet.
  static const syncApplyInProgress = 'sync_apply_in_progress';

  /// Set once the one-time legacy orphan cleanup has run.
  static const legacyOrphanCleanupDoneAtMs = 'legacy_orphan_cleanup_done_at_ms';

  /// File name (in the databases directory) of the pre-v3 safety backup.
  static const preSyncBackupFile = 'pre_sync_backup_file';
  static const preSyncBackupCreatedAtMs = 'pre_sync_backup_created_at_ms';

  /// Set if the pre-v3 backup could not be created (message only).
  static const preSyncBackupError = 'pre_sync_backup_error';

  // --- Phase B-3: first cloud connection ---------------------------------

  /// Email of [accountUid], for display only. Written with the binding.
  static const accountEmailHint = 'account_email_hint';

  /// `in_progress` / `failed` / `done` (see `InitialSyncState`).
  static const initialSyncState = 'initial_sync_state';

  /// `upload` / `restore` / `merge` / `bind_only`.
  static const initialSyncMode = 'initial_sync_mode';

  /// Account an unfinished initial sync was started for.
  static const initialSyncUid = 'initial_sync_uid';

  /// Last initial-sync failure (log text only).
  static const initialSyncError = 'initial_sync_error';

  // --- Phase B-4A: manual incremental sync --------------------------------

  /// Highest Firestore `serverUpdatedAt` (epoch ms) pulled per collection.
  /// Raised only after a fully successful manual sync.
  static const pullCursorSongsMs = 'pull_cursor_songs_ms';
  static const pullCursorFoldersMs = 'pull_cursor_folders_ms';
  static const pullCursorFolderSongsMs = 'pull_cursor_folder_songs_ms';

  /// File name and time of `songbook.pre_cloud_sync_v4.backup.db`.
  static const preCloudSyncBackupFile = 'pre_cloud_sync_backup_file';
  static const preCloudSyncBackupCreatedAtMs =
      'pre_cloud_sync_backup_created_at_ms';

  // --- Phase B-5: account deletion (key/value rows only, no schema change) --

  /// Stage of a started, unfinished account deletion
  /// (`AccountDeletionStage.storedName`). While present, every sync is
  /// refused. Removed when the deletion finishes.
  static const accountDeletionState = 'account_deletion_state';

  /// The account being deleted.
  static const accountDeletionUid = 'account_deletion_uid';
  static const accountDeletionStartedAtMs = 'account_deletion_started_at_ms';

  /// Cloud documents deleted so far (all attempts).
  static const accountDeletionDeletedDocs = 'account_deletion_deleted_docs';

  /// Every key describing a cloud binding / sync position. Removed by a
  /// finished account deletion (backup-file keys are kept: the files stay).
  static const cloudBindingKeys = [
    accountUid,
    accountEmailHint,
    lastSuccessfulSyncAtMs,
    initialSyncState,
    initialSyncMode,
    initialSyncUid,
    initialSyncError,
    pullCursorSongsMs,
    pullCursorFoldersMs,
    pullCursorFolderSongsMs,
  ];

  static const accountDeletionKeys = [
    accountDeletionState,
    accountDeletionUid,
    accountDeletionStartedAtMs,
    accountDeletionDeletedDocs,
  ];
}

/// Brings any database — fresh, legacy `user_version` 0, or v2 — to the
/// current schema. Idempotent: every step checks before acting, so it is
/// safe to run from `onCreate`, `onUpgrade` and `onOpen` alike, any number
/// of times. Never drops, renames, or rewrites existing columns or data;
/// the only writes to existing rows fill a `sync_id` that is NULL/empty.
Future<void> ensureSchema(DatabaseExecutor db) async {
  // Base tables, exactly as in the legacy app. IF NOT EXISTS because the
  // legacy database already has them (see kSongbookDatabaseVersion).
  await db.execute('''
    CREATE TABLE IF NOT EXISTS songs (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      karaoke_type TEXT NOT NULL,
      song_number TEXT NOT NULL,
      title TEXT NOT NULL,
      artist TEXT,
      key_type TEXT,
      key_offset INTEGER DEFAULT 0,
      difficulty TEXT,
      practice_status TEXT,
      memo TEXT,
      favorite INTEGER DEFAULT 0,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    )
  ''');
  await db.execute('''
    CREATE TABLE IF NOT EXISTS folders (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      name TEXT NOT NULL,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    )
  ''');
  await db.execute('''
    CREATE TABLE IF NOT EXISTS folder_songs (
      folder_id INTEGER NOT NULL,
      song_id INTEGER NOT NULL,
      added_at TEXT NOT NULL,
      PRIMARY KEY (folder_id, song_id)
    )
  ''');

  // v2
  await _ensureColumn(db, 'songs', 'search_aliases', 'TEXT');

  // v3: stable cross-device ids + UTC change timestamps. Nullable because
  // SQLite can't ADD COLUMN ... NOT NULL without a default; the repository
  // always fills them on write and the backfill below covers old rows.
  await _ensureColumn(db, 'songs', 'sync_id', 'TEXT');
  await _ensureColumn(db, 'songs', 'sync_updated_at_ms', 'INTEGER');
  await _ensureColumn(db, 'folders', 'sync_id', 'TEXT');
  await _ensureColumn(db, 'folders', 'sync_updated_at_ms', 'INTEGER');
  await _ensureColumn(db, 'folder_songs', 'sync_updated_at_ms', 'INTEGER');

  await db.execute('''
    CREATE TABLE IF NOT EXISTS sync_tombstones (
      entity_type TEXT NOT NULL,
      sync_id TEXT NOT NULL,
      related_sync_id TEXT NOT NULL DEFAULT '',
      deleted_at_ms INTEGER NOT NULL,
      PRIMARY KEY (entity_type, sync_id, related_sync_id)
    )
  ''');
  // v4: change tracking. After sync_tombstones is guaranteed to exist, so
  // fresh installs and upgrades both get the column through this path.
  await _ensureColumn(db, 'songs', 'sync_dirty', kSyncDirtyColumnDdl);
  await _ensureColumn(db, 'folders', 'sync_dirty', kSyncDirtyColumnDdl);
  await _ensureColumn(db, 'folder_songs', 'sync_dirty', kSyncDirtyColumnDdl);
  await _ensureColumn(db, 'sync_tombstones', 'sync_dirty', kSyncDirtyColumnDdl);

  // v5: membership revisions. Existing live rows get the DEFAULT (1) when
  // the column is added; nothing else in the row changes (sync_dirty
  // included). The tombstone column is nullable because it means nothing
  // for song/folder tombstones; legacy folder_song tombstones are filled
  // with 2 below, only where still NULL.
  await _ensureColumn(
    db,
    'folder_songs',
    'revision',
    'INTEGER NOT NULL DEFAULT $kFirstMembershipRevision',
  );
  await _ensureColumn(db, 'sync_tombstones', 'revision', 'INTEGER');

  await db.execute('''
    CREATE TABLE IF NOT EXISTS sync_meta (
      key TEXT PRIMARY KEY NOT NULL,
      value TEXT
    )
  ''');

  await db.rawUpdate(
    'UPDATE sync_tombstones SET revision = ? '
    'WHERE entity_type = ? AND revision IS NULL',
    [kLegacyMembershipRemovalRevision, TombstoneEntity.folderSong],
  );

  await _backfillSyncIds(db, 'songs');
  await _backfillSyncIds(db, 'folders');
  await _ensureUniqueSyncIdIndex(db, 'songs', 'idx_songs_sync_id');
  await _ensureUniqueSyncIdIndex(db, 'folders', 'idx_folders_sync_id');
}

Future<void> _ensureColumn(
  DatabaseExecutor db,
  String table,
  String column,
  String type,
) async {
  final columns = await db.rawQuery('PRAGMA table_info($table)');
  if (!columns.any((c) => c['name'] == column)) {
    await db.execute('ALTER TABLE $table ADD COLUMN $column $type');
  }
}

/// Gives every row without a sync id (NULL or '') a new one. Rows that
/// already have one are never touched, so ids are stable across reopens.
/// Only `sync_id` is written — `updated_at`, `sync_updated_at_ms` and every
/// legacy column keep their exact values.
Future<void> _backfillSyncIds(DatabaseExecutor db, String table) async {
  final rows = await db.rawQuery(
    "SELECT id FROM $table WHERE sync_id IS NULL OR sync_id = ''",
  );
  for (final row in rows) {
    await db.update(
      table,
      {'sync_id': generateSyncId()},
      where: "id = ? AND (sync_id IS NULL OR sync_id = '')",
      whereArgs: [row['id']],
    );
  }
}

Future<void> _ensureUniqueSyncIdIndex(
  DatabaseExecutor db,
  String table,
  String indexName,
) async {
  final existing = await db.rawQuery(
    "SELECT 1 FROM sqlite_master WHERE type = 'index' AND name = ?",
    [indexName],
  );
  if (existing.isNotEmpty) return;

  // Defensive: random v4 ids can't realistically collide, but if a row was
  // ever duplicated with its sync_id (e.g. by a manual copy), creating the
  // unique index would fail and the app could not open its database. Keep
  // the id on the lowest local id and re-issue the rest.
  final dupes = await db.rawQuery(
    'SELECT sync_id FROM $table WHERE sync_id IS NOT NULL '
    'GROUP BY sync_id HAVING COUNT(*) > 1',
  );
  for (final dupe in dupes) {
    final ids = await db.rawQuery(
      'SELECT id FROM $table WHERE sync_id = ? ORDER BY id',
      [dupe['sync_id']],
    );
    for (final row in ids.skip(1)) {
      await db.update(
        table,
        {'sync_id': generateSyncId()},
        where: 'id = ?',
        whereArgs: [row['id']],
      );
    }
  }
  await db.execute(
    'CREATE UNIQUE INDEX IF NOT EXISTS $indexName ON $table(sync_id)',
  );
}

Future<String?> readSyncMeta(DatabaseExecutor db, String key) async {
  final rows = await db.query(
    'sync_meta',
    columns: ['value'],
    where: 'key = ?',
    whereArgs: [key],
  );
  if (rows.isEmpty) return null;
  return rows.first['value'] as String?;
}

Future<void> writeSyncMeta(DatabaseExecutor db, String key, String value) {
  return db.insert(
    'sync_meta',
    {'key': key, 'value': value},
    conflictAlgorithm: ConflictAlgorithm.replace,
  );
}

/// Like [writeSyncMeta], but leaves an existing non-empty value untouched.
Future<void> writeSyncMetaIfMissing(
  DatabaseExecutor db,
  String key,
  String value,
) async {
  final current = await readSyncMeta(db, key);
  if (current != null && current.isNotEmpty) return;
  await writeSyncMeta(db, key, value);
}

/// Records (or refreshes) a deletion so a future sync can propagate it.
///
/// The defaults describe a *local* deletion: now, and dirty (needs
/// upload). The cloud-apply path passes the remote deletion time and
/// [SyncDirty.clean], because the cloud already has that deletion.
Future<void> recordTombstone(
  DatabaseExecutor db,
  String entityType,
  String syncId, {
  String relatedSyncId = '',
  int? deletedAtMs,
  int syncDirty = SyncDirty.dirty,
  int? revision,
}) {
  return db.insert(
    'sync_tombstones',
    {
      'entity_type': entityType,
      'sync_id': syncId,
      'related_sync_id': relatedSyncId,
      'deleted_at_ms': deletedAtMs ?? nowUtcMs(),
      'sync_dirty': syncDirty,
      'revision': revision,
    },
    conflictAlgorithm: ConflictAlgorithm.replace,
  );
}

/// Removes `folder_songs` rows whose `song_id` no longer exists — orphans
/// left by song deletions from before song deletion became transactional.
///
/// Previously this ran on *every* open. That's unsafe once sync exists: a
/// partially applied remote batch can contain memberships whose songs
/// haven't been written yet, and an every-launch cleanup would delete them.
/// Current code can no longer create orphans (song delete removes its
/// memberships in the same transaction), so a single pass is enough to
/// clean legacy data. It is also skipped while a sync batch is mid-apply.
/// Orphans are already invisible to the UI either way (`getSongIds` joins
/// against `songs`).
Future<void> runLegacyOrphanCleanupOnce(Database db) async {
  await db.transaction((txn) async {
    if (await readSyncMeta(txn, SyncMetaKeys.syncApplyInProgress) != null) {
      return;
    }
    if (await readSyncMeta(txn, SyncMetaKeys.legacyOrphanCleanupDoneAtMs) !=
        null) {
      return;
    }
    await txn.delete(
      'folder_songs',
      where: 'song_id NOT IN (SELECT id FROM songs)',
    );
    await writeSyncMeta(
      txn,
      SyncMetaKeys.legacyOrphanCleanupDoneAtMs,
      nowUtcMs().toString(),
    );
  });
}
