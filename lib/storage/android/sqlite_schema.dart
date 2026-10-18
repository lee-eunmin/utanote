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
const int kSongbookDatabaseVersion = 3;

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
  await db.execute('''
    CREATE TABLE IF NOT EXISTS sync_meta (
      key TEXT PRIMARY KEY NOT NULL,
      value TEXT
    )
  ''');

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
Future<void> recordTombstone(
  DatabaseExecutor db,
  String entityType,
  String syncId, {
  String relatedSyncId = '',
}) {
  return db.insert(
    'sync_tombstones',
    {
      'entity_type': entityType,
      'sync_id': syncId,
      'related_sync_id': relatedSyncId,
      'deleted_at_ms': nowUtcMs(),
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
