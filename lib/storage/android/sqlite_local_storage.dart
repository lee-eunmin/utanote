import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../../models/folder.dart';
import '../../models/song.dart';
import '../folder_repository.dart';
import '../local_storage.dart';
import '../song_repository.dart';

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
      onOpen: (db) => _ensureSearchAliasesColumn(db),
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
    final id = await _db.insert(_table, map);
    return song.copyWith(id: id);
  }

  @override
  Future<void> update(Song song) async {
    if (song.id == null) {
      throw ArgumentError('Cannot update a song without an id.');
    }
    await _db.update(
      _table,
      song.toDbMap(),
      where: 'id = ?',
      whereArgs: [song.id],
    );
  }

  @override
  Future<void> delete(int id) async {
    await _db.delete(_table, where: 'id = ?', whereArgs: [id]);
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
    final rows = await _db.query(
      _joinTable,
      columns: ['song_id'],
      where: 'folder_id = ?',
      whereArgs: [folderId],
    );
    return rows.map((r) => r['song_id'] as int).toList();
  }
}
