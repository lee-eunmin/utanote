import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:utanote/models/folder.dart';
import 'package:utanote/models/song.dart';
import 'package:utanote/storage/android/sqlite_local_storage.dart';
import 'package:utanote/storage/android/sqlite_pre_migration_backup.dart';
import 'package:utanote/storage/android/sqlite_schema.dart';
import 'package:utanote/storage/cloud_apply.dart';

/// Phase B-1: schema v4 (`sync_dirty`) and the cloud-apply write path,
/// against real SQLite via sqflite_common_ffi. Upgrade scenarios start from
/// a database shaped exactly like the v3 release's (Phase A), built here
/// with raw SQL so the test doesn't depend on the current ensureSchema().

const _songA = '11111111-1111-4111-8111-111111111111';
const _songB = '22222222-2222-4222-8222-222222222222';
const _songC = '33333333-3333-4333-8333-333333333333';
const _deletedSong = '44444444-4444-4444-8444-444444444444';
const _folderX = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const _folderY = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
const _deletedFolder = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';

/// v3 rows: a legacy row never edited since migration (NULL change time),
/// rows edited under v3, a KY row and a memo.
final _v3Songs = <Map<String, Object?>>[
  {
    'id': 1,
    'karaoke_type': 'KY',
    'song_number': '99',
    'title': '기존곡',
    'artist': '기존가수',
    'key_type': '남키',
    'key_offset': 2,
    'difficulty': '어려움',
    'practice_status': '연습 중',
    'memo': '레거시 메모',
    'favorite': 1,
    'created_at': '2020-01-01T00:00:00.000',
    'updated_at': '2020-02-01T09:30:15.123',
    'search_aliases': '["밤을 달리다","요루니카케루"]',
    'sync_id': _songA,
    'sync_updated_at_ms': null,
  },
  {
    'id': 2,
    'karaoke_type': 'TJ',
    'song_number': '54321',
    'title': '기존곡2',
    'artist': null,
    'key_type': '원키',
    'key_offset': -3,
    'difficulty': '쉬움',
    'practice_status': '완료',
    'memo': null,
    'favorite': 0,
    'created_at': '2021-06-15T00:00:00.000',
    'updated_at': '2021-06-15T00:00:00.000',
    'search_aliases': '[]',
    'sync_id': _songB,
    'sync_updated_at_ms': 1700000000000,
  },
  {
    'id': 5,
    'karaoke_type': 'TJ',
    'song_number': '777',
    'title': '같은시각곡',
    'artist': '가수3',
    'key_type': null,
    'key_offset': 0,
    'difficulty': null,
    'practice_status': null,
    'memo': '두번째 메모',
    'favorite': 1,
    'created_at': '2021-06-15T00:00:00.000',
    'updated_at': '2022-03-03T03:03:03.000',
    'search_aliases': null,
    'sync_id': _songC,
    'sync_updated_at_ms': 1710000000000,
  },
];

final _v3Folders = <Map<String, Object?>>[
  {
    'id': 1,
    'name': '기존폴더',
    'created_at': '2020-01-01T00:00:00.000',
    'updated_at': '2020-01-05T00:00:00.000',
    'sync_id': _folderX,
    'sync_updated_at_ms': null,
  },
  {
    'id': 3,
    'name': '두번째폴더',
    'created_at': '2021-01-01T00:00:00.000',
    'updated_at': '2021-01-01T00:00:00.000',
    'sync_id': _folderY,
    'sync_updated_at_ms': 1705000000000,
  },
];

final _v3Memberships = <Map<String, Object?>>[
  {'folder_id': 1, 'song_id': 1, 'added_at': '2020-01-02T00:00:00.000', 'sync_updated_at_ms': null},
  {'folder_id': 1, 'song_id': 2, 'added_at': '2021-06-16T00:00:00.000', 'sync_updated_at_ms': 1700000000001},
  {'folder_id': 3, 'song_id': 5, 'added_at': '2021-07-01T00:00:00.000', 'sync_updated_at_ms': 1710000000001},
];

final _v3Tombstones = <Map<String, Object?>>[
  {'entity_type': 'song', 'sync_id': _deletedSong, 'related_sync_id': '', 'deleted_at_ms': 1720000000000},
  {'entity_type': 'folder', 'sync_id': _deletedFolder, 'related_sync_id': '', 'deleted_at_ms': 1720000000001},
  {'entity_type': 'folder_song', 'sync_id': _folderY, 'related_sync_id': _songB, 'deleted_at_ms': 1720000000002},
];

final _v3Meta = <String, String>{
  'legacy_orphan_cleanup_done_at_ms': '1690000000000',
  'pre_sync_backup_file': 'songbook.pre_sync_v3.backup.db',
  'pre_sync_backup_created_at_ms': '1690000000000',
};

const _syncTables = ['songs', 'folders', 'folder_songs', 'sync_tombstones'];

void main() {
  late String dbPath;
  late String backupPath;
  final opened = <SqliteLocalStorage>[];

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    // Own directory: test files run in parallel and others use songbook.db.
    final tempDir = await Directory.systemTemp.createTemp('utanote_dirty_test_');
    await databaseFactory.setDatabasesPath(tempDir.path);
    final dbDir = await databaseFactory.getDatabasesPath();
    dbPath = p.join(dbDir, 'songbook.db');
    backupPath = p.join(dbDir, preSyncBackupFileName);
  });

  Future<void> wipe() async {
    for (final s in opened) {
      await s.close();
    }
    opened.clear();
    await databaseFactory.deleteDatabase(dbPath);
    await databaseFactory.deleteDatabase(backupPath);
  }

  setUp(wipe);
  tearDown(wipe);

  Future<SqliteLocalStorage> launch() async {
    final storage = SqliteLocalStorage();
    await storage.init();
    opened.add(storage);
    return storage;
  }

  Future<SqliteLocalStorage> relaunch(SqliteLocalStorage previous) async {
    await previous.close();
    opened.remove(previous);
    return launch();
  }

  /// A database exactly as the v3 release leaves it.
  Future<void> createV3Database() async {
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
    await db.execute('ALTER TABLE songs ADD COLUMN search_aliases TEXT');
    await db.execute('ALTER TABLE songs ADD COLUMN sync_id TEXT');
    await db.execute('ALTER TABLE songs ADD COLUMN sync_updated_at_ms INTEGER');
    await db.execute('ALTER TABLE folders ADD COLUMN sync_id TEXT');
    await db.execute('ALTER TABLE folders ADD COLUMN sync_updated_at_ms INTEGER');
    await db.execute('ALTER TABLE folder_songs ADD COLUMN sync_updated_at_ms INTEGER');
    await db.execute('''
      CREATE TABLE sync_tombstones (
        entity_type TEXT NOT NULL,
        sync_id TEXT NOT NULL,
        related_sync_id TEXT NOT NULL DEFAULT '',
        deleted_at_ms INTEGER NOT NULL,
        PRIMARY KEY (entity_type, sync_id, related_sync_id)
      )
    ''');
    await db.execute('''
      CREATE TABLE sync_meta (
        key TEXT PRIMARY KEY NOT NULL,
        value TEXT
      )
    ''');
    await db.execute('CREATE UNIQUE INDEX idx_songs_sync_id ON songs(sync_id)');
    await db.execute('CREATE UNIQUE INDEX idx_folders_sync_id ON folders(sync_id)');
    for (final r in _v3Songs) {
      await db.insert('songs', r);
    }
    for (final r in _v3Folders) {
      await db.insert('folders', r);
    }
    for (final r in _v3Memberships) {
      await db.insert('folder_songs', r);
    }
    for (final r in _v3Tombstones) {
      await db.insert('sync_tombstones', r);
    }
    for (final e in _v3Meta.entries) {
      await db.insert('sync_meta', {'key': e.key, 'value': e.value});
    }
    await db.setVersion(3);
    await db.close();
  }

  Future<List<Map<String, Object?>>> rowsOf(
    DatabaseExecutor db,
    String table, {
    List<String>? columns,
  }) {
    return db.query(table, columns: columns, orderBy: 'rowid');
  }

  /// Rows with the given columns only (i.e. without `sync_dirty`).
  List<Map<String, Object?>> withoutDirty(List<Map<String, Object?>> rows) {
    return [
      for (final r in rows) {...r}..remove('sync_dirty'),
    ];
  }

  Future<int?> dirtyOf(
    DatabaseExecutor db,
    String table,
    String where,
    List<Object?> args,
  ) async {
    final r = await db.query(table, columns: ['sync_dirty'], where: where, whereArgs: args);
    expect(r, hasLength(1), reason: '$table where $where $args');
    return r.single['sync_dirty'] as int?;
  }

  Future<void> markAllClean(DatabaseExecutor db) async {
    for (final t in _syncTables) {
      await db.update(t, {'sync_dirty': SyncDirty.clean});
    }
  }

  Song newSong(String number, {String? syncId}) {
    final now = DateTime.now();
    return Song(
      karaokeType: 'TJ',
      songNumber: number,
      title: '새곡$number',
      createdAt: now,
      updatedAt: now,
      syncId: syncId,
    );
  }

  Folder newFolder(String name, {String? syncId}) {
    final now = DateTime.now();
    return Folder(name: name, createdAt: now, updatedAt: now, syncId: syncId);
  }

  // ---------------------------------------------------------------------
  // v3 -> v4 upgrade.
  // ---------------------------------------------------------------------
  group('v3 -> v4 upgrade', () {
    test('every existing song value is preserved exactly', () async {
      await createV3Database();
      final storage = await launch();
      final db = storage.databaseForTesting;
      expect(await db.getVersion(), 4);
      expect(
        withoutDirty(await rowsOf(db, 'songs')),
        _v3Songs,
      );
      // The repository still reads them, KY row and memo included.
      final songs = await storage.songs.getAll();
      expect(songs.map((s) => s.syncId).toSet(), {_songA, _songB, _songC});
      final ky = songs.singleWhere((s) => s.id == 1);
      expect(ky.karaokeType, 'KY');
      expect(ky.memo, '레거시 메모');
      expect(ky.searchAliases, ['밤을 달리다', '요루니카케루']);
    });

    test('existing folders are preserved exactly', () async {
      await createV3Database();
      final db = (await launch()).databaseForTesting;
      expect(withoutDirty(await rowsOf(db, 'folders')), _v3Folders);
    });

    test('existing folder_songs are preserved exactly', () async {
      await createV3Database();
      final storage = await launch();
      final db = storage.databaseForTesting;
      expect(withoutDirty(await rowsOf(db, 'folder_songs')), _v3Memberships);
      expect(await storage.folders.getSongIds(1), unorderedEquals([1, 2]));
      expect(await storage.folders.getSongIds(3), [5]);
    });

    test('existing tombstones and sync_meta are preserved exactly', () async {
      await createV3Database();
      final db = (await launch()).databaseForTesting;
      expect(withoutDirty(await rowsOf(db, 'sync_tombstones')), _v3Tombstones);
      for (final e in _v3Meta.entries) {
        expect(await readSyncMeta(db, e.key), e.value);
      }
      expect(await readSyncMeta(db, SyncMetaKeys.accountUid), isNull);
      expect(await readSyncMeta(db, SyncMetaKeys.syncApplyInProgress), isNull);
    });

    test('every existing row in all four tables starts dirty (1)', () async {
      await createV3Database();
      final db = (await launch()).databaseForTesting;
      for (final t in _syncTables) {
        final dirty = await db.query(t, columns: ['sync_dirty']);
        expect(dirty, isNotEmpty, reason: t);
        expect(dirty.map((r) => r['sync_dirty']).toSet(), {1}, reason: t);
      }
    });

    test('sync_dirty is NOT NULL DEFAULT 1 on all four tables', () async {
      await createV3Database();
      final db = (await launch()).databaseForTesting;
      for (final t in _syncTables) {
        final info = await db.rawQuery('PRAGMA table_info($t)');
        final col = info.singleWhere((c) => c['name'] == 'sync_dirty');
        expect(col['notnull'], 1, reason: t);
        expect(col['dflt_value'], '1', reason: t);
        expect(col['type'], 'INTEGER', reason: t);
      }
    });

    test('does not create the pre-v3 backup for an already-v3 database', () async {
      await createV3Database();
      final storage = await launch();
      expect(storage.lastBackupResult!.status,
          PreMigrationBackupStatus.notNeededAlreadyMigrated);
      expect(await File(backupPath).exists(), isFalse);
    });

    test('repeated ensureSchema and relaunches leave schema and data identical', () async {
      await createV3Database();
      var storage = await launch();

      Future<Map<String, Object?>> snapshot(Database db) async => {
            'schema': await db.rawQuery(
                "SELECT type, name, sql FROM sqlite_master WHERE name NOT LIKE 'sqlite_%' ORDER BY name"),
            for (final t in [..._syncTables, 'sync_meta']) t: await rowsOf(db, t),
            'version': await db.getVersion(),
          };

      final first = await snapshot(storage.databaseForTesting);
      final db = storage.databaseForTesting;
      for (var i = 0; i < 3; i++) {
        await ensureSchema(db);
        await db.transaction((txn) => ensureSchema(txn));
      }
      expect(await snapshot(db), first);

      storage = await relaunch(storage);
      storage = await relaunch(storage);
      expect(await snapshot(storage.databaseForTesting), first);
    });

    test('a clean row stays clean across relaunch (migration does not reset it)', () async {
      await createV3Database();
      var storage = await launch();
      await markAllClean(storage.databaseForTesting);
      storage = await relaunch(storage);
      final db = storage.databaseForTesting;
      for (final t in _syncTables) {
        final dirty = await db.query(t, columns: ['sync_dirty']);
        expect(dirty.map((r) => r['sync_dirty']).toSet(), {0}, reason: t);
      }
    });
  });

  group('fresh install', () {
    test('gets sync_dirty on all four tables', () async {
      final db = (await launch()).databaseForTesting;
      expect(await db.getVersion(), kSongbookDatabaseVersion);
      for (final t in _syncTables) {
        final info = await db.rawQuery('PRAGMA table_info($t)');
        expect(info.map((c) => c['name']), contains('sync_dirty'), reason: t);
      }
    });
  });

  // ---------------------------------------------------------------------
  // Local (user) writes always mark dirty.
  // ---------------------------------------------------------------------
  group('local writes mark dirty', () {
    late SqliteLocalStorage storage;
    late Database db;

    setUp(() async {
      await createV3Database();
      storage = await launch();
      db = storage.databaseForTesting;
      // Start from "everything already synced", so every 1 below comes
      // from the write under test.
      await markAllClean(db);
    });

    test('new song', () async {
      final song = await storage.songs.create(newSong('100'));
      expect(await dirtyOf(db, 'songs', 'id = ?', [song.id]), 1);
    });

    test('edited song; sync_id and created_at untouched', () async {
      final before = await storage.songs.getById(2);
      await storage.songs.update(before!.copyWith(practiceStatus: '연습 중', favorite: true));
      expect(await dirtyOf(db, 'songs', 'id = ?', [2]), 1);
      final row = (await db.query('songs', where: 'id = 2')).single;
      expect(row['sync_id'], _songB);
      expect(row['created_at'], '2021-06-15T00:00:00.000');
      // Other rows untouched.
      expect(await dirtyOf(db, 'songs', 'id = ?', [1]), 0);
    });

    test('new folder', () async {
      final folder = await storage.folders.create(newFolder('새폴더'));
      expect(await dirtyOf(db, 'folders', 'id = ?', [folder.id]), 1);
    });

    test('renamed folder; sync_id untouched', () async {
      final folder = (await storage.folders.getAll()).singleWhere((f) => f.id == 1);
      await storage.folders.update(folder.copyWith(name: '이름변경'));
      expect(await dirtyOf(db, 'folders', 'id = ?', [1]), 1);
      expect((await db.query('folders', where: 'id = 1')).single['sync_id'], _folderX);
      expect(await dirtyOf(db, 'folders', 'id = ?', [3]), 0);
    });

    test('song added to folder', () async {
      await storage.folders.addSong(3, 1);
      expect(await dirtyOf(db, 'folder_songs', 'folder_id = ? AND song_id = ?', [3, 1]), 1);
    });

    test('adding an existing member changes nothing', () async {
      await storage.folders.addSong(1, 1);
      expect(await dirtyOf(db, 'folder_songs', 'folder_id = ? AND song_id = ?', [1, 1]), 0);
    });

    test('song delete tombstone', () async {
      await storage.songs.delete(1);
      expect(await db.query('songs', where: 'id = 1'), isEmpty);
      expect(await db.query('folder_songs', where: 'song_id = 1'), isEmpty);
      expect(
        await dirtyOf(db, 'sync_tombstones', 'entity_type = ? AND sync_id = ?', ['song', _songA]),
        1,
      );
    });

    test('folder delete tombstone; songs kept', () async {
      await storage.folders.delete(1);
      expect(await db.query('folders', where: 'id = 1'), isEmpty);
      expect(await db.query('songs'), hasLength(3));
      expect(
        await dirtyOf(db, 'sync_tombstones', 'entity_type = ? AND sync_id = ?', ['folder', _folderX]),
        1,
      );
    });

    test('remove-from-folder tombstone', () async {
      await storage.folders.removeSong(1, 2);
      expect(
        await dirtyOf(db, 'sync_tombstones',
            'entity_type = ? AND sync_id = ? AND related_sync_id = ?',
            ['folder_song', _folderX, _songB]),
        1,
      );
    });

    test('re-adding after removal: tombstone cleared, membership dirty', () async {
      // v3 fixture already has a removal record for (folderY, songB).
      await storage.folders.addSong(3, 2);
      expect(
        await db.query('sync_tombstones',
            where: 'entity_type = ? AND sync_id = ? AND related_sync_id = ?',
            whereArgs: ['folder_song', _folderY, _songB]),
        isEmpty,
      );
      expect(await dirtyOf(db, 'folder_songs', 'folder_id = ? AND song_id = ?', [3, 2]), 1);

      // And a fresh remove -> re-add cycle.
      await storage.folders.removeSong(1, 1);
      await markAllClean(db);
      await storage.folders.addSong(1, 1);
      expect(await dirtyOf(db, 'folder_songs', 'folder_id = ? AND song_id = ?', [1, 1]), 1);
      expect(
        await db.query('sync_tombstones',
            where: 'sync_id = ? AND related_sync_id = ?', whereArgs: [_folderX, _songA]),
        isEmpty,
      );
    });

    test('a user edit during a cloud apply is still dirty', () async {
      await writeSyncMeta(db, SyncMetaKeys.syncApplyInProgress, '1');
      final song = await storage.songs.create(newSong('200'));
      final folder = await storage.folders.create(newFolder('apply중'));
      await storage.folders.addSong(folder.id!, song.id!);
      expect(await dirtyOf(db, 'songs', 'id = ?', [song.id]), 1);
      expect(await dirtyOf(db, 'folders', 'id = ?', [folder.id]), 1);
      expect(await dirtyOf(db, 'folder_songs', 'folder_id = ? AND song_id = ?',
          [folder.id, song.id]), 1);
    });
  });

  // ---------------------------------------------------------------------
  // Cloud-apply path writes clean.
  // ---------------------------------------------------------------------
  group('cloud apply writes clean', () {
    const remoteSong = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd';
    const remoteFolder = 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee';

    late SqliteLocalStorage storage;
    late Database db;

    setUp(() async {
      await createV3Database();
      storage = await launch();
      db = storage.databaseForTesting;
    });

    test('new song from cloud is inserted clean with its sync_id', () async {
      final created = DateTime.parse('2023-04-05T06:07:08.000');
      final outcome = await storage.cloudApply.applyBatch(
        (w) => w.upsertSong(
          Song(
            id: 999, // ignored
            karaokeType: 'TJ',
            songNumber: '31337',
            title: '원격곡',
            createdAt: created,
            updatedAt: created,
            syncId: remoteSong,
          ),
          updatedAtMs: 1730000000000,
        ),
      );
      expect(outcome, CloudApplyOutcome.inserted);
      final row = (await db.query('songs', where: 'sync_id = ?', whereArgs: [remoteSong])).single;
      expect(row['sync_dirty'], 0);
      expect(row['sync_updated_at_ms'], 1730000000000);
      expect(row['created_at'], '2023-04-05T06:07:08.000');
      expect(row['id'], isNot(999));
    });

    test('existing dirty song updated from cloud becomes clean; ids unchanged', () async {
      final local = (await storage.songs.getById(2))!;
      final outcome = await storage.cloudApply.applyBatch(
        (w) => w.upsertSong(local.copyWith(id: 777, title: '원격수정'),
            updatedAtMs: 1740000000000),
      );
      expect(outcome, CloudApplyOutcome.updated);
      final row = (await db.query('songs', where: 'id = 2')).single;
      expect(row['title'], '원격수정');
      expect(row['sync_id'], _songB);
      expect(row['sync_dirty'], 0);
      expect(row['sync_updated_at_ms'], 1740000000000);
      expect(await db.query('songs'), hasLength(3));
    });

    test('folder from cloud: insert and update are clean', () async {
      final now = DateTime.parse('2024-01-01T00:00:00.000');
      await storage.cloudApply.applyBatch((w) async {
        expect(
          await w.upsertFolder(
              Folder(name: '원격폴더', createdAt: now, updatedAt: now, syncId: remoteFolder),
              updatedAtMs: 1),
          CloudApplyOutcome.inserted,
        );
        expect(
          await w.upsertFolder(
              Folder(name: '이름바뀜', createdAt: now, updatedAt: now, syncId: _folderX),
              updatedAtMs: 2),
          CloudApplyOutcome.updated,
        );
      });
      expect(await dirtyOf(db, 'folders', 'sync_id = ?', [remoteFolder]), 0);
      final x = (await db.query('folders', where: 'id = 1')).single;
      expect(x['name'], '이름바뀜');
      expect(x['sync_dirty'], 0);
      expect(x['sync_id'], _folderX);
    });

    test('membership from cloud is clean and clears the removal record', () async {
      await storage.cloudApply.applyBatch((w) async {
        expect(
          await w.upsertFolderSong(
            folderSyncId: _folderY,
            songSyncId: _songB,
            addedAt: DateTime.parse('2024-02-02T00:00:00.000'),
            updatedAtMs: 1750000000000,
          ),
          CloudApplyOutcome.inserted,
        );
        expect(
          await w.upsertFolderSong(
            folderSyncId: _folderX,
            songSyncId: _songA,
            addedAt: DateTime.parse('2020-01-02T00:00:00.000'),
            updatedAtMs: 1750000000001,
          ),
          CloudApplyOutcome.updated,
        );
      });
      expect(await dirtyOf(db, 'folder_songs', 'folder_id = ? AND song_id = ?', [3, 2]), 0);
      expect(await dirtyOf(db, 'folder_songs', 'folder_id = ? AND song_id = ?', [1, 1]), 0);
      expect(
        await db.query('sync_tombstones',
            where: 'entity_type = ? AND sync_id = ? AND related_sync_id = ?',
            whereArgs: ['folder_song', _folderY, _songB]),
        isEmpty,
      );
      expect(await storage.folders.getSongIds(3), unorderedEquals([5, 2]));
    });

    test('membership whose song or folder is missing is skipped', () async {
      final outcome = await storage.cloudApply.applyBatch(
        (w) => w.upsertFolderSong(
          folderSyncId: _folderX,
          songSyncId: remoteSong,
          addedAt: DateTime.now(),
          updatedAtMs: 1,
        ),
      );
      expect(outcome, CloudApplyOutcome.skippedMissingParent);
      expect(await db.query('folder_songs'), hasLength(3));
    });

    test('song deletion from cloud: row and memberships gone, tombstone clean', () async {
      await storage.cloudApply.applyBatch(
        (w) => w.applySongDeletion(_songA, deletedAtMs: 1760000000000),
      );
      expect(await db.query('songs', where: 'id = 1'), isEmpty);
      expect(await db.query('folder_songs', where: 'song_id = 1'), isEmpty);
      final t = (await db.query('sync_tombstones',
              where: 'entity_type = ? AND sync_id = ?', whereArgs: ['song', _songA]))
          .single;
      expect(t['sync_dirty'], 0);
      expect(t['deleted_at_ms'], 1760000000000);
    });

    test('folder deletion from cloud keeps songs; tombstone clean', () async {
      await storage.cloudApply.applyBatch(
        (w) => w.applyFolderDeletion(_folderX, deletedAtMs: 5),
      );
      expect(await db.query('folders', where: 'id = 1'), isEmpty);
      expect(await db.query('folder_songs', where: 'folder_id = 1'), isEmpty);
      expect(await db.query('songs'), hasLength(3));
      expect(await dirtyOf(db, 'sync_tombstones', 'entity_type = ? AND sync_id = ?',
          ['folder', _folderX]), 0);
    });

    test('membership removal from cloud; tombstone clean', () async {
      await storage.cloudApply.applyBatch(
        (w) => w.applyFolderSongRemoval(
            folderSyncId: _folderX, songSyncId: _songB, deletedAtMs: 6),
      );
      expect(await storage.folders.getSongIds(1), [1]);
      expect(
        await dirtyOf(db, 'sync_tombstones',
            'entity_type = ? AND sync_id = ? AND related_sync_id = ?',
            ['folder_song', _folderX, _songB]),
        0,
      );
    });

    test('a song or folder deleted here is never brought back by an upsert', () async {
      await storage.songs.delete(2); // local delete, dirty tombstone
      final now = DateTime.now();
      final outcomes = await storage.cloudApply.applyBatch((w) async => [
            await w.upsertSong(
                Song(karaokeType: 'TJ', songNumber: '1', title: 'x',
                    createdAt: now, updatedAt: now, syncId: _songB),
                updatedAtMs: 9999999999999),
            await w.upsertSong(
                Song(karaokeType: 'TJ', songNumber: '1', title: 'x',
                    createdAt: now, updatedAt: now, syncId: _deletedSong),
                updatedAtMs: 9999999999999),
            await w.upsertFolder(
                Folder(name: 'x', createdAt: now, updatedAt: now, syncId: _deletedFolder),
                updatedAtMs: 9999999999999),
          ]);
      expect(outcomes, everyElement(CloudApplyOutcome.skippedDeleted));
      expect(await db.query('songs', where: 'sync_id IN (?, ?)', whereArgs: [_songB, _deletedSong]),
          isEmpty);
      expect(await db.query('folders', where: 'sync_id = ?', whereArgs: [_deletedFolder]), isEmpty);
      // The local deletion is still waiting to be uploaded.
      expect(await dirtyOf(db, 'sync_tombstones', 'entity_type = ? AND sync_id = ?',
          ['song', _songB]), 1);
    });

    test('sync data without a sync id is rejected and nothing is written', () async {
      final now = DateTime.now();
      await expectLater(
        storage.cloudApply.applyBatch((w) => w.upsertSong(
            Song(karaokeType: 'TJ', songNumber: '1', title: 'x', createdAt: now, updatedAt: now),
            updatedAtMs: 1)),
        throwsArgumentError,
      );
      expect(await db.query('songs'), hasLength(3));
      expect(await storage.cloudApply.isApplyInProgress(), isFalse);
    });

    test('in-progress mark: set by a batch, survives relaunch, cleared by finishApply', () async {
      expect(await storage.cloudApply.isApplyInProgress(), isFalse);
      await storage.cloudApply.applyBatch((w) async {});
      expect(await storage.cloudApply.isApplyInProgress(), isTrue);

      storage = await relaunch(storage);
      expect(await storage.cloudApply.isApplyInProgress(), isTrue);

      await storage.cloudApply.finishApply();
      expect(await storage.cloudApply.isApplyInProgress(), isFalse);
    });

    test('a failing batch rolls back every write in it', () async {
      final now = DateTime.now();
      await expectLater(
        storage.cloudApply.applyBatch((w) async {
          await w.upsertSong(
              Song(karaokeType: 'TJ', songNumber: '1', title: 'x',
                  createdAt: now, updatedAt: now, syncId: remoteSong),
              updatedAtMs: 1);
          await w.applySongDeletion(_songA, deletedAtMs: 1);
          throw StateError('network dropped mid-batch');
        }),
        throwsStateError,
      );
      expect(await db.query('songs'), hasLength(3));
      expect(await db.query('songs', where: 'sync_id = ?', whereArgs: [remoteSong]), isEmpty);
      expect(await db.query('sync_tombstones', where: 'sync_id = ?', whereArgs: [_songA]),
          isEmpty);
      expect(await storage.cloudApply.isApplyInProgress(), isFalse);
    });

    test('cloud-applied rows stay clean after relaunch', () async {
      final now = DateTime.parse('2024-01-01T00:00:00.000');
      await storage.cloudApply.applyBatch((w) async {
        await w.upsertSong(
            Song(karaokeType: 'TJ', songNumber: '1', title: 'x',
                createdAt: now, updatedAt: now, syncId: remoteSong),
            updatedAtMs: 1);
      });
      await storage.cloudApply.finishApply();
      storage = await relaunch(storage);
      expect(await dirtyOf(storage.databaseForTesting, 'songs', 'sync_id = ?', [remoteSong]), 0);
    });
  });
}
