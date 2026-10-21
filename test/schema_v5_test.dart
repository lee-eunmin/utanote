import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:utanote/storage/android/sqlite_local_storage.dart';
import 'package:utanote/storage/android/sqlite_schema.dart';

/// Schema v5 (membership revisions): upgrades from the production v3
/// database and from the v4 development database, fresh installs, and
/// repeated ensureSchema runs. Built with raw SQL so the starting points
/// don't depend on the current ensureSchema().

const _songA = '11111111-1111-4111-8111-111111111111';
const _songB = '22222222-2222-4222-8222-222222222222';
const _songGone = '44444444-4444-4444-8444-444444444444';
const _folderX = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const _folderGone = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';

final _songs = [
  {
    'id': 1,
    'karaoke_type': 'KY',
    'song_number': '99',
    'title': '기존곡',
    'artist': '가수',
    'key_type': '남키',
    'key_offset': 2,
    'difficulty': '어려움',
    'practice_status': '연습 중',
    'memo': '레거시 메모',
    'favorite': 1,
    'created_at': '2020-01-01T00:00:00.000',
    'updated_at': '2020-02-01T09:30:15.123',
    'search_aliases': '["별칭"]',
    'sync_id': _songA,
    'sync_updated_at_ms': null,
  },
  {
    'id': 2,
    'karaoke_type': 'TJ',
    'song_number': '54321',
    'title': '기존곡2',
    'artist': null,
    'key_type': null,
    'key_offset': 0,
    'difficulty': null,
    'practice_status': null,
    'memo': null,
    'favorite': 0,
    'created_at': '2021-06-15T00:00:00.000',
    'updated_at': '2021-06-15T00:00:00.000',
    'search_aliases': '[]',
    'sync_id': _songB,
    'sync_updated_at_ms': 1700000000000,
  },
];

final _folders = [
  {
    'id': 1,
    'name': '기존폴더',
    'created_at': '2020-01-01T00:00:00.000',
    'updated_at': '2020-01-01T00:00:00.000',
    'sync_id': _folderX,
    'sync_updated_at_ms': null,
  },
];

final _memberships = [
  {
    'folder_id': 1,
    'song_id': 1,
    'added_at': '2020-01-02T00:00:00.000',
    'sync_updated_at_ms': null,
  },
];

final _tombstones = [
  {
    'entity_type': 'song',
    'sync_id': _songGone,
    'related_sync_id': '',
    'deleted_at_ms': 1720000000000,
  },
  {
    'entity_type': 'folder',
    'sync_id': _folderGone,
    'related_sync_id': '',
    'deleted_at_ms': 1720000000001,
  },
  {
    'entity_type': 'folder_song',
    'sync_id': _folderX,
    'related_sync_id': _songB,
    'deleted_at_ms': 1720000000002,
  },
];

const _tables = ['songs', 'folders', 'folder_songs', 'sync_tombstones'];

void main() {
  late String dbPath;
  final opened = <SqliteLocalStorage>[];

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final dir = await Directory.systemTemp.createTemp('utanote_schema_v5_');
    await databaseFactory.setDatabasesPath(dir.path);
    dbPath = p.join(dir.path, 'songbook.db');
  });

  Future<void> wipe() async {
    for (final s in opened) {
      await s.close();
    }
    opened.clear();
    await databaseFactory.deleteDatabase(dbPath);
    final backup = p.join(p.dirname(dbPath), 'songbook.pre_sync_v3.backup.db');
    if (await File(backup).exists()) await File(backup).delete();
  }

  setUp(wipe);
  tearDown(wipe);

  Future<SqliteLocalStorage> launch() async {
    final s = SqliteLocalStorage();
    await s.init();
    opened.add(s);
    return s;
  }

  /// The production (v3) database.
  Future<void> createV3() async {
    final db = await databaseFactory.openDatabase(dbPath);
    await db.execute('''
      CREATE TABLE songs (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        karaoke_type TEXT NOT NULL, song_number TEXT NOT NULL,
        title TEXT NOT NULL, artist TEXT, key_type TEXT,
        key_offset INTEGER DEFAULT 0, difficulty TEXT, practice_status TEXT,
        memo TEXT, favorite INTEGER DEFAULT 0,
        created_at TEXT NOT NULL, updated_at TEXT NOT NULL,
        search_aliases TEXT, sync_id TEXT, sync_updated_at_ms INTEGER
      )
    ''');
    await db.execute('''
      CREATE TABLE folders (
        id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL,
        created_at TEXT NOT NULL, updated_at TEXT NOT NULL,
        sync_id TEXT, sync_updated_at_ms INTEGER
      )
    ''');
    await db.execute('''
      CREATE TABLE folder_songs (
        folder_id INTEGER NOT NULL, song_id INTEGER NOT NULL,
        added_at TEXT NOT NULL, sync_updated_at_ms INTEGER,
        PRIMARY KEY (folder_id, song_id)
      )
    ''');
    await db.execute('''
      CREATE TABLE sync_tombstones (
        entity_type TEXT NOT NULL, sync_id TEXT NOT NULL,
        related_sync_id TEXT NOT NULL DEFAULT '', deleted_at_ms INTEGER NOT NULL,
        PRIMARY KEY (entity_type, sync_id, related_sync_id)
      )
    ''');
    await db.execute(
        'CREATE TABLE sync_meta (key TEXT PRIMARY KEY NOT NULL, value TEXT)');
    await db.execute('CREATE UNIQUE INDEX idx_songs_sync_id ON songs(sync_id)');
    await db.execute(
        'CREATE UNIQUE INDEX idx_folders_sync_id ON folders(sync_id)');
    for (final r in _songs) {
      await db.insert('songs', r);
    }
    for (final r in _folders) {
      await db.insert('folders', r);
    }
    for (final r in _memberships) {
      await db.insert('folder_songs', r);
    }
    for (final r in _tombstones) {
      await db.insert('sync_tombstones', r);
    }
    await db.setVersion(3);
    await db.close();
  }

  /// The v4 (development) database: v3 + sync_dirty, with mixed values
  /// (some rows already synced), which the upgrade must not touch.
  Future<void> createV4() async {
    await createV3();
    final db = await databaseFactory.openDatabase(dbPath);
    for (final t in _tables) {
      await db.execute(
          'ALTER TABLE $t ADD COLUMN sync_dirty INTEGER NOT NULL DEFAULT 1');
    }
    await db.update('songs', {'sync_dirty': 0}, where: 'id = 1');
    await db.update('folder_songs', {'sync_dirty': 0});
    await db.update('sync_tombstones', {'sync_dirty': 0},
        where: "entity_type = 'folder_song'");
    await db.setVersion(4);
    await db.close();
  }

  List<Map<String, Object?>> strip(
    List<Map<String, Object?>> rows,
    List<String> columns,
  ) =>
      [
        for (final r in rows)
          {...r}..removeWhere((k, _) => columns.contains(k)),
      ];

  Future<Map<String, List<Map<String, Object?>>>> dump(Database db) async => {
        for (final t in _tables) t: await db.query(t, orderBy: 'rowid'),
      };

  Future<void> expectRevisions(Database db) async {
    expect(
      (await db.query('folder_songs', columns: ['revision']))
          .map((r) => r['revision']),
      everyElement(kFirstMembershipRevision),
    );
    final tombs = {
      for (final r in await db.query('sync_tombstones'))
        r['entity_type']: r['revision'],
    };
    expect(tombs['folder_song'], kLegacyMembershipRemovalRevision);
    expect(tombs['song'], isNull);
    expect(tombs['folder'], isNull);
  }

  group('v3 -> v5', () {
    test('values, sync ids and rows are preserved; revisions backfilled',
        () async {
      await createV3();
      final db = (await launch()).databaseForTesting;
      expect(await db.getVersion(), 5);
      expect(strip(await db.query('songs', orderBy: 'id'), ['sync_dirty']),
          _songs);
      expect(strip(await db.query('folders', orderBy: 'id'), ['sync_dirty']),
          _folders);
      expect(
        strip(await db.query('folder_songs'), ['sync_dirty', 'revision']),
        _memberships,
      );
      expect(
        strip(await db.query('sync_tombstones', orderBy: 'rowid'),
            ['sync_dirty', 'revision']),
        _tombstones,
      );
      await expectRevisions(db);
    });
  });

  group('v4 -> v5', () {
    test('values and sync_dirty are untouched; revisions backfilled',
        () async {
      await createV4();
      final raw = await databaseFactory.openDatabase(dbPath);
      final before = await dump(raw);
      await raw.close();

      final db = (await launch()).databaseForTesting;
      expect(await db.getVersion(), 5);
      final after = await dump(db);
      for (final t in _tables) {
        expect(strip(after[t]!, ['revision']), before[t], reason: t);
      }
      await expectRevisions(db);
    });
  });

  group('fresh install v5', () {
    test('has the revision columns; first add is revision 1', () async {
      final s = await launch();
      final db = s.databaseForTesting;
      expect(await db.getVersion(), 5);
      final fs = await db.rawQuery('PRAGMA table_info(folder_songs)');
      final rev = fs.singleWhere((c) => c['name'] == 'revision');
      expect(rev['notnull'], 1);
      expect(rev['dflt_value'], '1');
      final ts = await db.rawQuery('PRAGMA table_info(sync_tombstones)');
      expect(ts.map((c) => c['name']), contains('revision'));
    });
  });

  group('ensureSchema', () {
    test('repeated runs and relaunches change nothing, and never overwrite '
        'a real revision', () async {
      await createV4();
      var s = await launch();
      final db = s.databaseForTesting;
      // A real (non-legacy) removal revision, written by new code.
      await db.update('sync_tombstones', {'revision': 4},
          where: "entity_type = 'folder_song'");
      final snapshot = await dump(db);
      final schema = await db.rawQuery(
          "SELECT name, sql FROM sqlite_master WHERE name NOT LIKE 'sqlite_%' "
          'ORDER BY name');
      for (var i = 0; i < 3; i++) {
        await db.transaction((txn) => ensureSchema(txn));
      }
      expect(await dump(db), snapshot);
      await s.close();
      opened.remove(s);
      s = await launch();
      final db2 = s.databaseForTesting;
      expect(await dump(db2), snapshot);
      expect(
        await db2.rawQuery(
            "SELECT name, sql FROM sqlite_master WHERE name NOT LIKE 'sqlite_%' "
            'ORDER BY name'),
        schema,
      );
    });
  });
}
