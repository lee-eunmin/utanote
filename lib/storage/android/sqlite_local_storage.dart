import 'dart:async';

import 'package:flutter/foundation.dart' show kDebugMode, debugPrint;
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../../models/folder.dart';
import '../../models/song.dart';
import '../folder_repository.dart';
import '../local_storage.dart';
import '../song_repository.dart';

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

/// Bumped from the legacy app's schema (which did not have
/// `search_aliases`). See [_onUpgrade] / [_ensureSearchAliasesColumn] for
/// the additive-only migration.
const int _databaseVersion = 2;

LocalStorage createLocalStorage() => SqliteLocalStorage();

class SqliteLocalStorage implements LocalStorage {
  Database? _db;
  SongRepository? _songs;
  FolderRepository? _folders;

  @override
  Future<void> init() async {
    if (_db != null) return;
    final dbDir = await getDatabasesPath();
    final path = p.join(dbDir, _databaseFileName);
    _db = await openDatabase(
      path,
      version: _databaseVersion,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
      onOpen: (db) async {
        await _ensureSearchAliasesColumn(db);
        await _cleanupOrphanedFolderSongs(db);
      },
    );
    _songs = _SqliteSongRepository(_db!);
    _folders = _SqliteFolderRepository(_db!);
  }

  @override
  SongRepository get songs {
    final repo = _songs;
    if (repo == null) {
      throw StateError('SqliteLocalStorage.init() must be awaited first.');
    }
    return repo;
  }

  @override
  FolderRepository get folders {
    final repo = _folders;
    if (repo == null) {
      throw StateError('SqliteLocalStorage.init() must be awaited first.');
    }
    return repo;
  }

  static Future<void> _onCreate(Database db, int version) async {
    // Fresh installs only. Existing installs go through _onUpgrade instead,
    // so this schema is safe to keep in sync with the latest columns.
    await db.execute('''
      CREATE TABLE songs (
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
        search_aliases TEXT,
        favorite INTEGER DEFAULT 0,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE folders (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE folder_songs (
        folder_id INTEGER NOT NULL,
        song_id INTEGER NOT NULL,
        added_at TEXT NOT NULL,
        PRIMARY KEY (folder_id, song_id)
      )
    ''');
  }

  /// Upgrades an existing database in place. This must only ever ADD
  /// columns/tables — never drop or rewrite existing ones — since the
  /// database being upgraded may be the real production `songbook.db` from
  /// the already-published app, containing real user data.
  static Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      await _ensureSearchAliasesColumn(db);
    }
    // Ensure folder tables exist even if upgrading from a legacy version
    // that predates them, without touching `songs`.
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
  }

  /// Defensive, idempotent check that runs on every open. This guards
  /// against the legacy database's on-disk `user_version` not matching what
  /// we expect (e.g. if the old app tracked schema versions differently),
  /// so we never rely solely on [oldVersion] to decide whether the column
  /// already exists.
  static Future<void> _ensureSearchAliasesColumn(Database db) async {
    final columns = await db.rawQuery('PRAGMA table_info(songs)');
    final hasColumn = columns.any((c) => c['name'] == 'search_aliases');
    if (!hasColumn) {
      await db.execute('ALTER TABLE songs ADD COLUMN search_aliases TEXT');
    }
  }

  /// Removes `folder_songs` rows left over from song deletions that predate
  /// this fix (a song was deleted without also deleting its folder_songs
  /// rows, leaving folder counts overstated). Only ever deletes rows in the
  /// join table whose `song_id` no longer exists in `songs` — never touches
  /// `songs` or `folders` themselves. Cheap and safe to re-run on every open.
  static Future<void> _cleanupOrphanedFolderSongs(Database db) async {
    await db.delete(
      'folder_songs',
      where: 'song_id NOT IN (SELECT id FROM songs)',
    );
  }
}

class _SqliteSongRepository implements SongRepository {
  final Database _db;
  static const _table = 'songs';

  _SqliteSongRepository(this._db);

  @override
  Future<List<Song>> getAll() async {
    final rows = await _db.query(_table, orderBy: 'title COLLATE NOCASE');
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
    final map = song.toDbMap()..remove('id');
    _diagLog('create(): calling _db.insert for "${song.title}"');
    try {
      final id = await _db.insert(_table, map).timeout(_writeTimeout);
      _diagLog('create(): _db.insert returned id=$id');
      return song.copyWith(id: id);
    } on TimeoutException {
      // The plugin call didn't reply in time. Rather than hang forever (the
      // observed bug) or blindly retry the insert (which would duplicate
      // the row if the original write actually did land), check whether it
      // already committed and, if so, recover the id from it instead of
      // inserting again.
      _diagLog('create(): _db.insert timed out; checking whether it committed anyway');
      final recovered = await _findJustInserted(map).timeout(
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

  /// Looks up the row a just-attempted (but unconfirmed) insert would have
  /// produced, matching on the fields that make it unique in practice
  /// (karaoke_type/song_number/title/created_at — created_at is the
  /// millisecond-precision timestamp this specific create() call used, so a
  /// match here is effectively unambiguous). Used only to recover from a
  /// lost insert() reply, never to decide whether to insert in the first
  /// place.
  Future<Song?> _findJustInserted(Map<String, Object?> map) async {
    final rows = await _db.query(
      _table,
      where: 'karaoke_type = ? AND song_number = ? AND title = ? AND created_at = ?',
      whereArgs: [
        map['karaoke_type'],
        map['song_number'],
        map['title'],
        map['created_at'],
      ],
      orderBy: 'id DESC',
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
    final map = song.toDbMap();
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
    // folder counts keep counting a song that no longer exists. Both writes
    // happen in one transaction so a failure can't leave one without the
    // other.
    await _db.transaction((txn) async {
      await txn.delete(
        'folder_songs',
        where: 'song_id = ?',
        whereArgs: [id],
      );
      await txn.delete(_table, where: 'id = ?', whereArgs: [id]);
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
      orderBy: 'title COLLATE NOCASE',
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
    return rows.map(Folder.fromMap).toList();
  }

  @override
  Future<Folder> create(Folder folder) async {
    final map = folder.toMap()..remove('id');
    final id = await _db.insert(_table, map);
    return folder.copyWith(id: id);
  }

  @override
  Future<void> update(Folder folder) async {
    if (folder.id == null) {
      throw ArgumentError('Cannot update a folder without an id.');
    }
    await _db.update(
      _table,
      folder.toMap(),
      where: 'id = ?',
      whereArgs: [folder.id],
    );
  }

  @override
  Future<void> delete(int id) async {
    await _db.delete(_table, where: 'id = ?', whereArgs: [id]);
    await _db.delete(_joinTable, where: 'folder_id = ?', whereArgs: [id]);
  }

  @override
  Future<void> addSong(int folderId, int songId) async {
    await _db.insert(
      _joinTable,
      {
        'folder_id': folderId,
        'song_id': songId,
        'added_at': DateTime.now().toIso8601String(),
      },
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  @override
  Future<void> removeSong(int folderId, int songId) async {
    await _db.delete(
      _joinTable,
      where: 'folder_id = ? AND song_id = ?',
      whereArgs: [folderId, songId],
    );
  }

  @override
  Future<List<int>> getSongIds(int folderId) async {
    // Joined against `songs` so a folder_songs row left over from a song
    // deletion (e.g. one that predates this fix, before the on-open
    // cleanup runs) never counts as a member.
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
