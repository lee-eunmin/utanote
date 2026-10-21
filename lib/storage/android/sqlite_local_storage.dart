import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart'
    show kDebugMode, debugPrint, visibleForTesting;
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../../models/folder.dart';
import '../../models/song.dart';
import '../cloud_apply.dart';
import '../folder_repository.dart';
import '../local_storage.dart';
import '../song_repository.dart';
import '../sync_id.dart';
import 'sqlite_cloud_apply.dart';
import 'sqlite_pre_migration_backup.dart';
import 'sqlite_schema.dart';

/// Bound on how long a single write's plugin round-trip is allowed to hang
/// before we treat it as suspect. This is a *safety net*, not the primary
/// completion signal: the normal path is still a plain `await` on the
/// sqflite call. See [_SqliteSongRepository.create] / `.update` for why this
/// exists — on Android, sqflite's method-channel reply for a write has been
/// observed to occasionally never arrive back in the running Dart isolate
/// even though the write already committed to disk (confirmed by the row
/// being present after an app restart). Generous on purpose so it never
/// fires under normal (even slow-emulator) conditions.
const Duration _writeTimeout = Duration(seconds: 8);

/// Temporary diagnostic logging for investigating the Android save-hang
/// bug (see CLAUDE.md task history). Gated on [kDebugMode] so it never
/// prints in release builds; safe to delete entirely once the fix is
/// confirmed on-device.
void _diagLog(String message) {
  if (kDebugMode) {
    debugPrint('[songbook.db][diag] $message');
  }
}

/// Database filename must stay `songbook.db` — the existing (pre-rewrite)
/// Android app already ships a database with this name, and opening a
/// different filename would silently orphan all existing user data instead
/// of migrating it. See CLAUDE.md.
const String _databaseFileName = 'songbook.db';

LocalStorage createLocalStorage() => SqliteLocalStorage();

class SqliteLocalStorage implements LocalStorage {
  Database? _db;
  SongRepository? _songs;
  FolderRepository? _folders;
  CloudApplyStore? _cloudApply;

  /// Outcome of the one-time pre-migration backup attempted by [init].
  PreMigrationBackupResult? lastBackupResult;

  @override
  Future<void> init() async {
    if (_db != null) return;
    final dbDir = await getDatabasesPath();
    final path = p.join(dbDir, _databaseFileName);

    // Must run before openDatabase: once opened at the new version, the
    // migration has already modified the file. Never throws; a failed
    // backup leaves the original untouched and startup continues (the
    // migration itself is additive-only and transactional).
    final backup = await backupBeforeMigrationIfNeeded(
      databasePath: path,
      targetVersion: kPreSyncBackupTargetVersion,
    );
    lastBackupResult = backup;

    _db = await openDatabase(
      path,
      version: kSongbookDatabaseVersion,
      // IMPORTANT: sqflite calls onCreate — not onUpgrade — whenever the
      // on-disk `user_version` is 0, regardless of whether the file already
      // has tables. The legacy app's songbook.db is exactly that (populated
      // tables, user_version 0), so onCreate runs for upgrading users too.
      // ensureSchema is idempotent and non-destructive for that reason.
      onCreate: (db, version) => ensureSchema(db),
      onUpgrade: (db, oldVersion, newVersion) => ensureSchema(db),
      onOpen: (db) async {
        // Re-checked on every open rather than trusting user_version alone.
        await db.transaction((txn) => ensureSchema(txn));
        await _recordBackupResult(db, backup);
        await runLegacyOrphanCleanupOnce(db);
      },
    );
    _songs = _SqliteSongRepository(_db!);
    _folders = _SqliteFolderRepository(_db!);
    _cloudApply = SqliteCloudApplyStore(_db!);
  }

  /// Raw connection, for tests that assert on the on-disk schema/rows.
  @visibleForTesting
  Database get databaseForTesting => _db!;

  /// Closes the connection. The app never needs this (it keeps one
  /// connection for its lifetime); tests use it to simulate a restart.
  Future<void> close() async {
    await _db?.close();
    _db = null;
    _songs = null;
    _folders = null;
    _cloudApply = null;
  }

  static Future<void> _recordBackupResult(
    Database db,
    PreMigrationBackupResult backup,
  ) async {
    switch (backup.status) {
      case PreMigrationBackupStatus.created:
        await _recordBackupFileMeta(db, backup.backupPath!, nowUtcMs());
      case PreMigrationBackupStatus.alreadyExists:
        // Covers a backup made on an earlier launch whose metadata never
        // got written (app killed between the backup and onOpen). The time
        // is recovered from the file's modification time, which is set
        // when the backup is written and never touched afterwards.
        final file = File(backup.backupPath!);
        if (await file.exists()) {
          final modified = await file.lastModified();
          await _recordBackupFileMeta(
            db,
            backup.backupPath!,
            modified.toUtc().millisecondsSinceEpoch,
          );
        }
      case PreMigrationBackupStatus.failed:
        final message = backup.error.toString();
        await writeSyncMeta(
          db,
          SyncMetaKeys.preSyncBackupError,
          message.length > 500 ? message.substring(0, 500) : message,
        );
      case PreMigrationBackupStatus.notNeededFreshInstall:
      case PreMigrationBackupStatus.notNeededAlreadyMigrated:
        break;
    }
  }

  /// Writes the backup's file name and creation time to `sync_meta`, but
  /// only for keys that are missing or empty — a value already recorded is
  /// never overwritten. Reads the backup file's metadata only; never
  /// rewrites the file itself.
  static Future<void> _recordBackupFileMeta(
    Database db,
    String backupPath,
    int createdAtMs,
  ) async {
    await writeSyncMetaIfMissing(
      db,
      SyncMetaKeys.preSyncBackupFile,
      p.basename(backupPath),
    );
    await writeSyncMetaIfMissing(
      db,
      SyncMetaKeys.preSyncBackupCreatedAtMs,
      createdAtMs.toString(),
    );
  }

  @override
  SongRepository get songs {
    final repo = _songs;
    if (repo == null) {
      throw StateError('SqliteLocalStorage.init() must be awaited first.');
    }
    return repo;
  }

  /// The cloud account uid this database is bound to
  /// (`sync_meta.account_uid`), or null if unbound. Read-only; sign-in
  /// never writes it.
  Future<String?> readBoundAccountUid() async {
    final db = _db;
    if (db == null) {
      throw StateError('SqliteLocalStorage.init() must be awaited first.');
    }
    final value = await readSyncMeta(db, SyncMetaKeys.accountUid);
    return (value == null || value.isEmpty) ? null : value;
  }

  /// Path for writing changes received from the cloud (stored clean,
  /// `sync_dirty = 0`). User edits go through [songs]/[folders] instead,
  /// which always store rows as dirty. Not part of [LocalStorage]: Web has
  /// no sync yet.
  CloudApplyStore get cloudApply {
    final store = _cloudApply;
    if (store == null) {
      throw StateError('SqliteLocalStorage.init() must be awaited first.');
    }
    return store;
  }

  @override
  FolderRepository get folders {
    final repo = _folders;
    if (repo == null) {
      throw StateError('SqliteLocalStorage.init() must be awaited first.');
    }
    return repo;
  }
}

/// Looks up a row's sync id inside [txn], or null if the row is missing or
/// (shouldn't happen after migration) has none.
Future<String?> _syncIdOf(DatabaseExecutor txn, String table, int id) async {
  final rows = await txn.query(
    table,
    columns: ['sync_id'],
    where: 'id = ?',
    whereArgs: [id],
  );
  if (rows.isEmpty) return null;
  final value = rows.first['sync_id'] as String?;
  return hasSyncId(value) ? value : null;
}

class _SqliteSongRepository implements SongRepository {
  final Database _db;
  static const _table = 'songs';

  /// Default "newest first" ordering — see [compareSongsNewestFirst] in
  /// `models/song.dart`, which the Web and in-memory storages use for the
  /// same effect. `created_at` is stored as an ISO-8601 string produced by
  /// `DateTime.toIso8601String()`, which sorts lexicographically in the same
  /// order as chronologically, so a plain SQL `ORDER BY` works here without
  /// needing to parse dates.
  static const _newestFirstOrderBy = 'created_at DESC, id DESC';

  _SqliteSongRepository(this._db);

  @override
  Future<List<Song>> getAll() async {
    final rows = await _db.query(_table, orderBy: _newestFirstOrderBy);
    return rows.map(Song.fromDbMap).toList();
  }

  @override
  Future<Song?> getById(int id) async {
    final rows = await _db.query(_table, where: 'id = ?', whereArgs: [id]);
    if (rows.isEmpty) return null;
    return Song.fromDbMap(rows.first);
  }

  @override
  Future<Song> create(Song song) async {
    final syncId = hasSyncId(song.syncId) ? song.syncId! : generateSyncId();
    final map = song.toDbMap()
      ..remove('id')
      ..['sync_id'] = syncId
      ..['sync_updated_at_ms'] = nowUtcMs()
      ..['sync_dirty'] = SyncDirty.dirty;
    _diagLog('create(): calling _db.insert for "${song.title}"');
    try {
      final id = await _db.insert(_table, map).timeout(_writeTimeout);
      _diagLog('create(): _db.insert returned id=$id');
      return song.copyWith(id: id, syncId: syncId);
    } on TimeoutException {
      // The plugin call didn't reply in time. Rather than hang forever (the
      // observed bug) or blindly retry the insert (which would duplicate
      // the row if the original write actually did land), check whether it
      // already committed and, if so, recover the id from it instead of
      // inserting again. The sync id is unique, so this lookup is exact.
      _diagLog('create(): _db.insert timed out; checking whether it committed anyway');
      final recovered = await _findBySyncId(syncId).timeout(
        _writeTimeout,
        onTimeout: () => null,
      );
      if (recovered != null) {
        _diagLog('create(): recovered committed row id=${recovered.id}');
        return recovered;
      }
      _diagLog('create(): no matching row found; rethrowing timeout');
      rethrow;
    }
  }

  /// Used only to recover from a lost insert() reply, never to decide
  /// whether to insert in the first place.
  Future<Song?> _findBySyncId(String syncId) async {
    final rows = await _db.query(
      _table,
      where: 'sync_id = ?',
      whereArgs: [syncId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return Song.fromDbMap(rows.first);
  }

  @override
  Future<void> update(Song song) async {
    if (song.id == null) {
      throw ArgumentError('Cannot update a song without an id.');
    }
    // sync_id is immutable once assigned, whatever the caller's copy holds.
    final map = song.toDbMap()
      ..remove('sync_id')
      ..['sync_updated_at_ms'] = nowUtcMs()
      ..['sync_dirty'] = SyncDirty.dirty;
    _diagLog('update(): calling _db.update for id=${song.id}');
    try {
      await _db
          .update(_table, map, where: 'id = ?', whereArgs: [song.id])
          .timeout(_writeTimeout);
      _diagLog('update(): _db.update returned');
    } on TimeoutException {
      // update() is naturally idempotent (same WHERE id = ?, same values),
      // so — unlike create() — it's safe to simply retry once rather than
      // needing a separate recovery lookup: if the first attempt's reply
      // was merely lost after already committing, re-applying the same
      // values is a no-op.
      _diagLog('update(): _db.update timed out; retrying once');
      await _db
          .update(_table, map, where: 'id = ?', whereArgs: [song.id])
          .timeout(_writeTimeout);
      _diagLog('update(): retry completed');
    }
  }

  @override
  Future<void> delete(int id) async {
    // Deleting a song must also drop its folder_songs membership rows, or
    // folder counts keep counting a song that no longer exists. The row is
    // still hard-deleted (so no query needs a "deleted" filter); a
    // tombstone keyed by its sync id records the deletion for future sync.
    // All in one transaction so none can happen without the others.
    // Memberships removed here get no tombstones of their own: a deleted
    // song implies all of its memberships are gone.
    await _db.transaction((txn) async {
      final syncId = await _syncIdOf(txn, _table, id);
      await txn.delete(
        'folder_songs',
        where: 'song_id = ?',
        whereArgs: [id],
      );
      final deleted = await txn.delete(_table, where: 'id = ?', whereArgs: [id]);
      if (deleted > 0 && syncId != null) {
        await recordTombstone(txn, TombstoneEntity.song, syncId);
      }
    });
  }

  @override
  Future<List<Song>> search(String query) async {
    final needle = '%$query%';
    final rows = await _db.query(
      _table,
      where:
          'song_number LIKE ? OR title LIKE ? OR artist LIKE ? OR search_aliases LIKE ?',
      whereArgs: [needle, needle, needle, needle],
      orderBy: _newestFirstOrderBy,
    );
    return rows.map(Song.fromDbMap).toList();
  }
}

class _SqliteFolderRepository implements FolderRepository {
  final Database _db;
  static const _table = 'folders';
  static const _joinTable = 'folder_songs';

  _SqliteFolderRepository(this._db);

  @override
  Future<List<Folder>> getAll() async {
    final rows = await _db.query(_table, orderBy: 'name COLLATE NOCASE');
    return rows.map(Folder.fromDbMap).toList();
  }

  @override
  Future<Folder> create(Folder folder) async {
    final syncId = hasSyncId(folder.syncId) ? folder.syncId! : generateSyncId();
    final map = folder.toDbMap()
      ..remove('id')
      ..['sync_id'] = syncId
      ..['sync_updated_at_ms'] = nowUtcMs()
      ..['sync_dirty'] = SyncDirty.dirty;
    final id = await _db.insert(_table, map);
    return folder.copyWith(id: id, syncId: syncId);
  }

  @override
  Future<void> update(Folder folder) async {
    if (folder.id == null) {
      throw ArgumentError('Cannot update a folder without an id.');
    }
    final map = folder.toDbMap()
      ..remove('sync_id')
      ..['sync_updated_at_ms'] = nowUtcMs()
      ..['sync_dirty'] = SyncDirty.dirty;
    await _db.update(_table, map, where: 'id = ?', whereArgs: [folder.id]);
  }

  @override
  Future<void> delete(int id) async {
    // Removes the folder and its membership rows only — never the songs.
    // One transaction (previously two separate statements) so a crash
    // can't leave memberships pointing at a deleted folder.
    await _db.transaction((txn) async {
      final syncId = await _syncIdOf(txn, _table, id);
      await txn.delete(_joinTable, where: 'folder_id = ?', whereArgs: [id]);
      final deleted = await txn.delete(_table, where: 'id = ?', whereArgs: [id]);
      if (deleted > 0 && syncId != null) {
        await recordTombstone(txn, TombstoneEntity.folder, syncId);
      }
    });
  }

  @override
  Future<void> addSong(int folderId, int songId) async {
    await _db.transaction((txn) async {
      // Checked explicitly instead of relying on insert()'s return value
      // for an ignored conflict, which differs between sqflite platforms.
      final existing = await txn.query(
        _joinTable,
        columns: ['folder_id'],
        where: 'folder_id = ? AND song_id = ?',
        whereArgs: [folderId, songId],
      );
      if (existing.isNotEmpty) return; // already a member: unchanged
      await txn.insert(
        _joinTable,
        {
          'folder_id': folderId,
          'song_id': songId,
          'added_at': DateTime.now().toIso8601String(),
          'sync_updated_at_ms': nowUtcMs(),
          'sync_dirty': SyncDirty.dirty,
        },
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
      // Re-adding a previously removed song: the membership is live again,
      // so its removal tombstone no longer applies.
      final folderSyncId = await _syncIdOf(txn, _table, folderId);
      final songSyncId = await _syncIdOf(txn, 'songs', songId);
      if (folderSyncId != null && songSyncId != null) {
        await txn.delete(
          'sync_tombstones',
          where: 'entity_type = ? AND sync_id = ? AND related_sync_id = ?',
          whereArgs: [TombstoneEntity.folderSong, folderSyncId, songSyncId],
        );
      }
    });
  }

  @override
  Future<void> removeSong(int folderId, int songId) async {
    await _db.transaction((txn) async {
      final removed = await txn.delete(
        _joinTable,
        where: 'folder_id = ? AND song_id = ?',
        whereArgs: [folderId, songId],
      );
      if (removed > 0) {
        final folderSyncId = await _syncIdOf(txn, _table, folderId);
        final songSyncId = await _syncIdOf(txn, 'songs', songId);
        if (folderSyncId != null && songSyncId != null) {
          await recordTombstone(
            txn,
            TombstoneEntity.folderSong,
            folderSyncId,
            relatedSyncId: songSyncId,
          );
        }
      }
    });
  }

  @override
  Future<List<int>> getSongIds(int folderId) async {
    // Joined against `songs` so a folder_songs row left over from a song
    // deletion (e.g. one that predates the transactional delete) never
    // counts as a member.
    final rows = await _db.rawQuery(
      '''
      SELECT fs.song_id AS song_id
      FROM $_joinTable fs
      INNER JOIN songs s ON s.id = fs.song_id
      WHERE fs.folder_id = ?
      ''',
      [folderId],
    );
    return rows.map((r) => r['song_id'] as int).toList();
  }
}
