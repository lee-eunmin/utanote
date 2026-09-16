import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:utanote/models/folder.dart';
import 'package:utanote/models/song.dart';
import 'package:utanote/storage/android/sqlite_local_storage.dart';

/// Regression coverage for the on-device bug where updating the already
/// published (legacy) Play Store app crashed on startup with
/// `DatabaseException: table songs already exists`.
///
/// Root cause: the legacy app's `songbook.db` was never versioned through
/// sqflite's `version:` parameter, so its on-disk `PRAGMA user_version` is
/// `0` even though the file already has real `songs` / `folders` /
/// `folder_songs` data. sqflite calls `onCreate` — not `onUpgrade` —
/// whenever `user_version` is `0`, regardless of whether the file already
/// has tables. `_onCreate` used to run a plain `CREATE TABLE songs`, which
/// throws against that populated legacy file.
///
/// These tests run against real SQLite via `sqflite_common_ffi` (the
/// standard way to unit test sqflite code — the native plugin used by
/// [SqliteLocalStorage] doesn't run under `flutter test`) and drive a
/// hand-built "legacy" database file through `SqliteLocalStorage.init()`,
/// the same entry point `main.dart` uses.
void main() {
  late String dbPath;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    dbPath = p.join(await databaseFactoryFfi.getDatabasesPath(), 'songbook.db');
  });

  setUp(() async {
    await databaseFactory.deleteDatabase(dbPath);
  });

  tearDown(() async {
    await databaseFactory.deleteDatabase(dbPath);
  });

  /// Builds a database file matching the legacy (pre-rewrite) app's schema:
  /// tables already exist, no `search_aliases` column, and — critically —
  /// opened without an sqflite `version`, so `PRAGMA user_version` stays at
  /// SQLite's default of `0`, exactly like a real device's already-published
  /// app database.
  Future<void> createLegacyDatabase({
    required List<Map<String, Object?>> songs,
    List<Map<String, Object?>> folders = const [],
    List<Map<String, Object?>> folderSongs = const [],
  }) async {
    final db = await databaseFactory.openDatabase(dbPath);
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
    for (final song in songs) {
      await db.insert('songs', song);
    }
    for (final folder in folders) {
      await db.insert('folders', folder);
    }
    for (final row in folderSongs) {
      await db.insert('folder_songs', row);
    }
    // Sanity check the fixture itself is a faithful stand-in for the real
    // legacy database before handing it to the code under test.
    expect(
      await db.getVersion(),
      0,
      reason: 'fixture must reproduce the unversioned legacy db',
    );
    await db.close();
  }

  test('fresh install creates all tables and can persist data', () async {
    expect(await databaseFactory.databaseExists(dbPath), isFalse);

    final storage = SqliteLocalStorage();
    await storage.init();

    final folder = await storage.folders.create(
      Folder(name: '연습', createdAt: DateTime.now(), updatedAt: DateTime.now()),
    );
    final song = await storage.songs.create(
      Song(
        karaokeType: 'TJ',
        songNumber: '12345',
        title: '테스트곡',
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      ),
    );
    await storage.folders.addSong(folder.id!, song.id!);

    expect(await storage.songs.getAll(), hasLength(1));
    expect(await storage.folders.getSongIds(folder.id!), [song.id]);
  });

  test(
    'upgrading a legacy (unversioned, pre-existing tables) database does not throw',
    () async {
      await createLegacyDatabase(
        songs: [
          {
            'karaoke_type': 'KY',
            'song_number': '99',
            'title': '기존곡',
            'artist': '기존가수',
            'key_type': '남',
            'key_offset': 2,
            'difficulty': '상',
            'practice_status': '연습중',
            'memo': '레거시 메모',
            'favorite': 1,
            'created_at': '2020-01-01T00:00:00.000',
            'updated_at': '2020-01-01T00:00:00.000',
          },
        ],
      );

      final storage = SqliteLocalStorage();
      // This is the exact call that crashed on-device with
      // `DatabaseException: table songs already exists` before the fix.
      await expectLater(storage.init(), completes);
    },
  );

  test('existing songs, folders, and folder_songs survive the upgrade', () async {
    await createLegacyDatabase(
      songs: [
        {
          'karaoke_type': 'KY',
          'song_number': '99',
          'title': '기존곡',
          'artist': '기존가수',
          'key_type': '남',
          'key_offset': 2,
          'difficulty': '상',
          'practice_status': '연습중',
          'memo': '레거시 메모',
          'favorite': 1,
          'created_at': '2020-01-01T00:00:00.000',
          'updated_at': '2020-01-01T00:00:00.000',
        },
        {
          'karaoke_type': 'TJ',
          'song_number': '54321',
          'title': '기존곡2',
          'favorite': 0,
          'created_at': '2021-06-15T00:00:00.000',
          'updated_at': '2021-06-15T00:00:00.000',
        },
      ],
      folders: [
        {
          'name': '기존폴더',
          'created_at': '2020-01-01T00:00:00.000',
          'updated_at': '2020-01-01T00:00:00.000',
        },
      ],
      folderSongs: [
        {'folder_id': 1, 'song_id': 1, 'added_at': '2020-01-02T00:00:00.000'},
      ],
    );

    final storage = SqliteLocalStorage();
    await storage.init();

    final songs = await storage.songs.getAll();
    expect(songs, hasLength(2));

    final preserved = songs.firstWhere((s) => s.songNumber == '99');
    expect(preserved.karaokeType, 'KY');
    expect(preserved.title, '기존곡');
    expect(preserved.artist, '기존가수');
    expect(preserved.keyType, '남');
    expect(preserved.keyOffset, 2);
    expect(preserved.difficulty, '상');
    expect(preserved.practiceStatus, '연습중');
    expect(preserved.memo, '레거시 메모');
    expect(preserved.favorite, isTrue);

    final folders = await storage.folders.getAll();
    expect(folders, hasLength(1));
    expect(folders.single.name, '기존폴더');
    expect(await storage.folders.getSongIds(folders.single.id!), [1]);
  });

  test('search_aliases column is added to a legacy database without one', () async {
    await createLegacyDatabase(
      songs: [
        {
          'karaoke_type': 'TJ',
          'song_number': '1',
          'title': '곡',
          'favorite': 0,
          'created_at': '2020-01-01T00:00:00.000',
          'updated_at': '2020-01-01T00:00:00.000',
        },
      ],
    );

    final storage = SqliteLocalStorage();
    await storage.init();

    // The migrated column exists and legacy rows read back as "no aliases"
    // rather than crashing or silently losing the row.
    final songs = await storage.songs.getAll();
    expect(songs.single.searchAliases, isEmpty);

    // Newly written aliases persist through the migrated column.
    final updated = songs.single.copyWith(searchAliases: ['별명']);
    await storage.songs.update(updated);
    final reloaded = await storage.songs.getById(updated.id!);
    expect(reloaded!.searchAliases, ['별명']);
  });

  test('migration is idempotent across repeated opens of the same database', () async {
    await createLegacyDatabase(songs: const []);

    await SqliteLocalStorage().init();

    // Simulate the app fully restarting: close the connection so the next
    // init() really reopens from disk (now at user_version 2) instead of
    // reusing sqflite's singleInstance cache.
    final db = await databaseFactory.openDatabase(dbPath);
    await db.close();

    await expectLater(SqliteLocalStorage().init(), completes);
  });
}
