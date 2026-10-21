import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:utanote/models/folder.dart';
import 'package:utanote/models/song.dart';
import 'package:utanote/storage/android/sqlite_local_storage.dart';
import 'package:utanote/storage/android/sqlite_pre_migration_backup.dart';
import 'package:utanote/storage/android/sqlite_schema.dart';

/// Phase A (cloud-sync readiness) migration safety, against real SQLite via
/// sqflite_common_ffi. Every scenario starts from a database file shaped
/// like a real existing user's — the legacy FlutterFlow app's
/// (`user_version` 0) or this rewrite's previous release (`user_version`
/// 2) — and drives it through `SqliteLocalStorage.init()`, the same entry
/// point `main.dart` uses.
final _uuidV4 = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
);

const _legacySongColumns = [
  'id', 'karaoke_type', 'song_number', 'title', 'artist', 'key_type',
  'key_offset', 'difficulty', 'practice_status', 'memo', 'favorite',
  'created_at', 'updated_at',
];

/// Rows as they'd exist on a real device. Includes a KY row, a memo,
/// non-default key/difficulty/status/favorite, two songs sharing a
/// created_at (exercises the `id DESC` tie-break), and local-time
/// timestamps without an offset, exactly as the app writes them.
final _fixtureSongs = <Map<String, Object?>>[
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
  },
  {
    'id': 3,
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
  },
];

final _fixtureFolders = <Map<String, Object?>>[
  {
    'id': 1,
    'name': '기존폴더',
    'created_at': '2020-01-01T00:00:00.000',
    'updated_at': '2020-01-05T00:00:00.000',
  },
  {
    'id': 2,
    'name': '두번째폴더',
    'created_at': '2021-01-01T00:00:00.000',
    'updated_at': '2021-01-01T00:00:00.000',
  },
];

final _fixtureMemberships = <Map<String, Object?>>[
  {'folder_id': 1, 'song_id': 1, 'added_at': '2020-01-02T00:00:00.000'},
  {'folder_id': 1, 'song_id': 2, 'added_at': '2021-06-16T00:00:00.000'},
  {'folder_id': 2, 'song_id': 3, 'added_at': '2021-07-01T00:00:00.000'},
];

/// Membership pointing at a song that no longer exists — left behind by
/// the legacy non-transactional song delete.
const _orphanMembership = {
  'folder_id': 1,
  'song_id': 999,
  'added_at': '2020-03-03T00:00:00.000',
};

/// v2 rows carry search_aliases (JSON text), keyed by song id.
const _fixtureAliases = {
  1: '["밤을 달리다","요루니카케루"]',
  2: '[]',
  3: null,
};

void main() {
  late String dbDir;
  late String dbPath;
  late String backupPath;
  final opened = <SqliteLocalStorage>[];

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    // Own directory: `flutter test` runs test files in parallel, and other
    // files also use songbook.db in the default ffi databases path.
    final tempDir = await Directory.systemTemp.createTemp('utanote_sync_test_');
    await databaseFactory.setDatabasesPath(tempDir.path);
    dbDir = await databaseFactory.getDatabasesPath();
    dbPath = p.join(dbDir, 'songbook.db');
    backupPath = p.join(dbDir, preSyncBackupFileName);
  });

  Future<void> wipeTestFiles() async {
    for (final s in opened) {
      await s.close();
    }
    opened.clear();
    await databaseFactory.deleteDatabase(dbPath);
    await databaseFactory.deleteDatabase(backupPath);
    final tmp = '$backupPath.tmp';
    if (await Directory(tmp).exists()) await Directory(tmp).delete();
    await databaseFactory.deleteDatabase(tmp);
  }

  setUp(wipeTestFiles);
  tearDown(wipeTestFiles);

  Future<SqliteLocalStorage> launch() async {
    final storage = SqliteLocalStorage();
    await storage.init();
    opened.add(storage);
    return storage;
  }

  /// Simulates a full app restart: close the connection, then open again.
  Future<SqliteLocalStorage> relaunch(SqliteLocalStorage previous) async {
    await previous.close();
    opened.remove(previous);
    return launch();
  }

  /// Builds an existing user's database at [version] (0 = legacy, 2 =
  /// previous release), optionally with a legacy orphan membership.
  Future<void> createExistingDatabase(int version, {bool withOrphan = false}) async {
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
    if (version >= 2) {
      await db.execute('ALTER TABLE songs ADD COLUMN search_aliases TEXT');
    }
    for (final song in _fixtureSongs) {
      await db.insert('songs', {
        ...song,
        if (version >= 2) 'search_aliases': _fixtureAliases[song['id']],
      });
    }
    for (final folder in _fixtureFolders) {
      await db.insert('folders', folder);
    }
    for (final row in _fixtureMemberships) {
      await db.insert('folder_songs', row);
    }
    if (withOrphan) await db.insert('folder_songs', _orphanMembership);
    if (version > 0) await db.setVersion(version);
    expect(await db.getVersion(), version);
    await db.close();
  }

  Future<List<Map<String, Object?>>> rows(
    DatabaseExecutor db,
    String table, {
    List<String>? columns,
    String orderBy = 'rowid',
  }) {
    return db.query(table, columns: columns, orderBy: orderBy);
  }

  Future<Set<String>> columnsOf(DatabaseExecutor db, String table) async {
    final info = await db.rawQuery('PRAGMA table_info($table)');
    return info.map((c) => c['name'] as String).toSet();
  }

  Future<Map<int, String>> syncIds(DatabaseExecutor db, String table) async {
    final r = await db.query(table, columns: ['id', 'sync_id']);
    return {for (final row in r) row['id'] as int: row['sync_id'] as String};
  }

  // ---------------------------------------------------------------------
  // Existing users: legacy (user_version 0) and previous release (v2).
  // ---------------------------------------------------------------------
  for (final fromVersion in [0, 2]) {
    group('existing user database at user_version $fromVersion', () {
      test('every legacy song value is preserved exactly', () async {
        await createExistingDatabase(fromVersion);
        final storage = await launch();
        final db = storage.databaseForTesting;

        expect(await db.getVersion(), kSongbookDatabaseVersion);
        final after = await rows(db, 'songs', columns: _legacySongColumns);
        expect(after, _fixtureSongs, reason: 'raw column values must be untouched');

        // memo / aliases / key / difficulty / status / favorite through the model.
        final byId = {for (final s in await storage.songs.getAll()) s.id!: s};
        expect(byId[1]!.memo, '레거시 메모');
        expect(byId[3]!.memo, '두번째 메모');
        expect(byId[1]!.karaokeType, 'KY');
        expect(byId[1]!.keyType, '남키');
        expect(byId[1]!.keyOffset, 2);
        expect(byId[1]!.difficulty, '어려움');
        expect(byId[1]!.practiceStatus, '연습 중');
        expect(byId[1]!.favorite, isTrue);
        expect(byId[2]!.favorite, isFalse);
        expect(byId[2]!.keyOffset, -3);
        expect(
          byId[1]!.searchAliases,
          fromVersion >= 2 ? ['밤을 달리다', '요루니카케루'] : isEmpty,
        );

        final aliasesRaw = await rows(db, 'songs', columns: ['id', 'search_aliases']);
        for (final row in aliasesRaw) {
          expect(
            row['search_aliases'],
            fromVersion >= 2 ? _fixtureAliases[row['id']] : isNull,
            reason: 'search_aliases must not be rewritten or backfilled',
          );
        }
      });

      test('created_at / updated_at strings are not rewritten or converted', () async {
        await createExistingDatabase(fromVersion);
        final storage = await launch();
        final db = storage.databaseForTesting;

        final songTimes = await rows(db, 'songs', columns: ['id', 'created_at', 'updated_at']);
        expect(songTimes, [
          for (final s in _fixtureSongs)
            {'id': s['id'], 'created_at': s['created_at'], 'updated_at': s['updated_at']},
        ]);
        final folderTimes = await rows(db, 'folders', columns: ['id', 'created_at', 'updated_at']);
        expect(folderTimes, [
          for (final f in _fixtureFolders)
            {'id': f['id'], 'created_at': f['created_at'], 'updated_at': f['updated_at']},
        ]);
        // No UTC change time is invented for rows that haven't changed.
        for (final row in await rows(db, 'songs', columns: ['sync_updated_at_ms'])) {
          expect(row['sync_updated_at_ms'], isNull);
        }
        for (final row in await rows(db, 'folders', columns: ['sync_updated_at_ms'])) {
          expect(row['sync_updated_at_ms'], isNull);
        }
      });

      test('folders and folder_songs are preserved', () async {
        await createExistingDatabase(fromVersion);
        final storage = await launch();
        final db = storage.databaseForTesting;

        expect(
          await rows(db, 'folders', columns: ['id', 'name', 'created_at', 'updated_at']),
          _fixtureFolders,
        );
        expect(
          await rows(db, 'folder_songs', columns: ['folder_id', 'song_id', 'added_at']),
          _fixtureMemberships,
        );
        expect(await storage.folders.getSongIds(1), unorderedEquals([1, 2]));
        expect(await storage.folders.getSongIds(2), [3]);
      });

      test('default ordering (created_at DESC, id DESC) is unchanged', () async {
        await createExistingDatabase(fromVersion);
        final storage = await launch();
        expect((await storage.songs.getAll()).map((s) => s.id), [3, 2, 1]);
      });

      test('every existing song and folder gets a unique UUID sync_id', () async {
        await createExistingDatabase(fromVersion);
        final storage = await launch();
        final db = storage.databaseForTesting;

        final songIds = await syncIds(db, 'songs');
        final folderIds = await syncIds(db, 'folders');
        expect(songIds.keys, unorderedEquals([1, 2, 3]));
        expect(folderIds.keys, unorderedEquals([1, 2]));
        final all = [...songIds.values, ...folderIds.values];
        for (final id in all) {
          expect(id, matches(_uuidV4));
        }
        expect(all.toSet(), hasLength(all.length), reason: 'ids must be unique');

        // Also exposed on the models.
        final songs = await storage.songs.getAll();
        expect(songs.map((s) => s.syncId).toSet(), songIds.values.toSet());
        final folders = await storage.folders.getAll();
        expect(folders.map((f) => f.syncId).toSet(), folderIds.values.toSet());
      });

      test('sync_ids do not change across relaunches', () async {
        await createExistingDatabase(fromVersion);
        var storage = await launch();
        final songsBefore = await syncIds(storage.databaseForTesting, 'songs');
        final foldersBefore = await syncIds(storage.databaseForTesting, 'folders');

        for (var i = 0; i < 3; i++) {
          storage = await relaunch(storage);
          expect(await syncIds(storage.databaseForTesting, 'songs'), songsBefore);
          expect(await syncIds(storage.databaseForTesting, 'folders'), foldersBefore);
        }
      });

      test('repeated migration is safe: schema and data stay identical', () async {
        await createExistingDatabase(fromVersion);
        var storage = await launch();
        final db1 = storage.databaseForTesting;
        Future<Map<String, Object>> snapshot(Database db) async => {
          for (final t in ['songs', 'folders', 'folder_songs', 'sync_tombstones', 'sync_meta'])
            '$t.columns': (await columnsOf(db, t)).toList()..sort(),
          for (final t in ['songs', 'folders', 'folder_songs'])
            '$t.rows': await rows(db, t),
          'indexes': (await db.rawQuery(
            "SELECT name FROM sqlite_master WHERE type = 'index' ORDER BY name",
          )),
        };
        final first = await snapshot(db1);

        // Running the migration directly again on an open db is a no-op.
        await db1.transaction((txn) => ensureSchema(txn));
        await ensureSchema(db1);
        expect(await snapshot(db1), first);

        storage = await relaunch(storage);
        storage = await relaunch(storage);
        expect(await snapshot(storage.databaseForTesting), first);
      });

      test('the pre-migration backup is an exact copy of the old database', () async {
        await createExistingDatabase(fromVersion);
        final storage = await launch();

        expect(storage.lastBackupResult!.status, PreMigrationBackupStatus.created);
        expect(storage.lastBackupResult!.backupPath, backupPath);
        expect(await File(backupPath).exists(), isTrue);
        expect(await File('$backupPath.tmp').exists(), isFalse);

        final backup = await databaseFactory.openDatabase(
          backupPath,
          options: OpenDatabaseOptions(readOnly: true, singleInstance: false),
        );
        try {
          expect(await backup.getVersion(), fromVersion, reason: 'pre-migration state');
          expect(await columnsOf(backup, 'songs'), isNot(contains('sync_id')));
          expect(await rows(backup, 'songs', columns: _legacySongColumns), _fixtureSongs);
          expect(await rows(backup, 'folders'), _fixtureFolders);
          expect(await rows(backup, 'folder_songs'), _fixtureMemberships);
        } finally {
          await backup.close();
        }

        final meta = storage.databaseForTesting;
        expect(await readSyncMeta(meta, SyncMetaKeys.preSyncBackupFile), preSyncBackupFileName);
        expect(await readSyncMeta(meta, SyncMetaKeys.preSyncBackupCreatedAtMs), isNotNull);
        expect(await readSyncMeta(meta, SyncMetaKeys.preSyncBackupError), isNull);
      });

      test('the backup is made once, and never overwritten on later launches', () async {
        await createExistingDatabase(fromVersion);
        var storage = await launch();
        final firstBytes = await File(backupPath).readAsBytes();

        // Data changes after migration must not leak into the backup.
        await storage.songs.delete(1);
        storage = await relaunch(storage);
        expect(storage.lastBackupResult!.status, PreMigrationBackupStatus.alreadyExists);
        expect(await File(backupPath).readAsBytes(), firstBytes);

        // Even if the backup file is gone, an already-migrated database is
        // never backed up again.
        await File(backupPath).delete();
        storage = await relaunch(storage);
        expect(
          storage.lastBackupResult!.status,
          PreMigrationBackupStatus.notNeededAlreadyMigrated,
        );
        expect(await File(backupPath).exists(), isFalse);
      });

      test('a failed backup leaves the original intact and the app still opens', () async {
        await createExistingDatabase(fromVersion);
        // Block the temp path with a directory so the copy fails.
        await Directory('$backupPath.tmp').create(recursive: true);

        final storage = await launch();
        expect(storage.lastBackupResult!.status, PreMigrationBackupStatus.failed);
        expect(await File(backupPath).exists(), isFalse);
        expect(await Directory('$backupPath.tmp').exists(), isTrue,
            reason: 'only files the backup created may be removed');

        final db = storage.databaseForTesting;
        expect(await rows(db, 'songs', columns: _legacySongColumns), _fixtureSongs);
        expect((await syncIds(db, 'songs')).values, everyElement(matches(_uuidV4)));
        expect(await readSyncMeta(db, SyncMetaKeys.preSyncBackupError), isNotNull);
      });

      test('legacy orphan memberships are cleaned once, as before', () async {
        await createExistingDatabase(fromVersion, withOrphan: true);
        final storage = await launch();
        final db = storage.databaseForTesting;

        expect(
          await rows(db, 'folder_songs', columns: ['folder_id', 'song_id', 'added_at']),
          _fixtureMemberships,
        );
        expect(await storage.folders.getSongIds(1), unorderedEquals([1, 2]));
        expect(await readSyncMeta(db, SyncMetaKeys.legacyOrphanCleanupDoneAtMs), isNotNull);
        // The backup still holds the pre-cleanup state, orphan included.
        final backup = await databaseFactory.openDatabase(
          backupPath,
          options: OpenDatabaseOptions(readOnly: true, singleInstance: false),
        );
        expect(await rows(backup, 'folder_songs'), hasLength(_fixtureMemberships.length + 1));
        await backup.close();
      });
    });
  }

  // ---------------------------------------------------------------------
  // Fresh installs and new rows.
  // ---------------------------------------------------------------------
  group('fresh install', () {
    test('creates the full current schema and no backup', () async {
      final storage = await launch();
      final db = storage.databaseForTesting;
      expect(storage.lastBackupResult!.status, PreMigrationBackupStatus.notNeededFreshInstall);
      expect(await File(backupPath).exists(), isFalse);
      expect(await db.getVersion(), kSongbookDatabaseVersion);
      expect(await columnsOf(db, 'songs'), containsAll([
        ..._legacySongColumns, 'search_aliases', 'sync_id', 'sync_updated_at_ms',
      ]));
      expect(await columnsOf(db, 'folders'), containsAll(['sync_id', 'sync_updated_at_ms']));
      expect(await columnsOf(db, 'folder_songs'),
          containsAll(['sync_updated_at_ms', 'revision']));
      expect(await columnsOf(db, 'sync_tombstones'), {
        'entity_type',
        'sync_id',
        'related_sync_id',
        'deleted_at_ms',
        'sync_dirty',
        'revision',
      });
      expect(await columnsOf(db, 'sync_meta'), {'key', 'value'});

      // Account/sync markers are reserved but empty.
      expect(await readSyncMeta(db, SyncMetaKeys.accountUid), isNull);
      expect(await readSyncMeta(db, SyncMetaKeys.lastSuccessfulSyncAtMs), isNull);

      final next = await relaunch(storage);
      expect(next.lastBackupResult!.status, PreMigrationBackupStatus.notNeededAlreadyMigrated);
      expect(await File(backupPath).exists(), isFalse);
    });
  });

  group('new and edited rows', () {
    Song newSong(String number) {
      final now = DateTime.now();
      return Song(
        karaokeType: 'TJ',
        songNumber: number,
        title: '새곡$number',
        createdAt: now,
        updatedAt: now,
      );
    }

    Folder newFolder(String name) {
      final now = DateTime.now();
      return Folder(name: name, createdAt: now, updatedAt: now);
    }

    test('new songs and folders always get a UUID and a UTC change time', () async {
      await createExistingDatabase(2);
      final storage = await launch();
      final db = storage.databaseForTesting;
      final before = DateTime.now().toUtc().millisecondsSinceEpoch;

      final song = await storage.songs.create(newSong('1'));
      final folder = await storage.folders.create(newFolder('새폴더'));
      final after = DateTime.now().toUtc().millisecondsSinceEpoch;

      expect(song.syncId, matches(_uuidV4));
      expect(folder.syncId, matches(_uuidV4));
      final songRow = (await db.query('songs', where: 'id = ?', whereArgs: [song.id])).single;
      final folderRow = (await db.query('folders', where: 'id = ?', whereArgs: [folder.id])).single;
      expect(songRow['sync_id'], song.syncId);
      expect(folderRow['sync_id'], folder.syncId);
      expect(songRow['sync_updated_at_ms'] as int, inInclusiveRange(before, after));
      expect(folderRow['sync_updated_at_ms'] as int, inInclusiveRange(before, after));

      final existing = await syncIds(db, 'songs');
      expect(existing.values.toSet(), hasLength(existing.length));
      // Newest first still holds with the new song on top.
      expect((await storage.songs.getAll()).first.id, song.id);
    });

    test('edits (favorite, status, aliases, key, rename) keep sync_id stable', () async {
      await createExistingDatabase(2);
      final storage = await launch();
      final db = storage.databaseForTesting;
      final originalSongIds = await syncIds(db, 'songs');
      final originalFolderIds = await syncIds(db, 'folders');

      final song = (await storage.songs.getById(1))!;
      // A caller can't change sync_id, even by passing a different one.
      await storage.songs.update(song.copyWith(
        favorite: false,
        practiceStatus: '완료',
        searchAliases: ['새별명'],
        keyType: '여키',
        keyOffset: -1,
        updatedAt: DateTime(2030),
        syncId: 'not-allowed',
      ));
      final folder = (await storage.folders.getAll()).firstWhere((f) => f.id == 1);
      await storage.folders.update(folder.copyWith(name: '바뀐이름', syncId: 'nope'));

      expect(await syncIds(db, 'songs'), originalSongIds);
      expect(await syncIds(db, 'folders'), originalFolderIds);
      final reloaded = (await storage.songs.getById(1))!;
      expect(reloaded.favorite, isFalse);
      expect(reloaded.practiceStatus, '완료');
      expect(reloaded.searchAliases, ['새별명']);
      expect(reloaded.keyType, '여키');
      expect(reloaded.keyOffset, -1);
      expect(reloaded.memo, '레거시 메모', reason: 'memo survives edits');
      expect(reloaded.createdAt, DateTime.parse('2020-01-01T00:00:00.000'));
      final row = (await db.query('songs', where: 'id = 1')).single;
      expect(row['created_at'], '2020-01-01T00:00:00.000');
      expect(row['sync_updated_at_ms'], isNotNull);
      expect((await storage.folders.getAll()).map((f) => f.name), contains('바뀐이름'));
    });

    test('an empty-string sync_id is replaced; valid ones are left alone', () async {
      await createExistingDatabase(2);
      var storage = await launch();
      final before = await syncIds(storage.databaseForTesting, 'songs');
      await storage.databaseForTesting.update('songs', {'sync_id': ''}, where: 'id = 2');

      storage = await relaunch(storage);
      final after = await syncIds(storage.databaseForTesting, 'songs');
      expect(after[1], before[1]);
      expect(after[3], before[3]);
      expect(after[2], matches(_uuidV4));
      expect(after[2], isNot(before[2]));
    });
  });

  // ---------------------------------------------------------------------
  // Delete tracking.
  // ---------------------------------------------------------------------
  group('tombstones', () {
    Future<List<Map<String, Object?>>> tombstones(Database db) =>
        db.query('sync_tombstones', orderBy: 'entity_type, sync_id');

    test('deleting a migrated song records its sync_id and hides it', () async {
      await createExistingDatabase(0);
      final storage = await launch();
      final db = storage.databaseForTesting;
      final songSyncId = (await syncIds(db, 'songs'))[1]!;
      final before = DateTime.now().toUtc().millisecondsSinceEpoch;

      await storage.songs.delete(1);

      final t = (await tombstones(db)).single;
      expect(t['entity_type'], TombstoneEntity.song);
      expect(t['sync_id'], songSyncId);
      expect(t['related_sync_id'], '');
      expect(t['deleted_at_ms'] as int, greaterThanOrEqualTo(before));
      expect((await storage.songs.getAll()).map((s) => s.id), [3, 2]);
      expect(await storage.songs.search('기존곡'), everyElement(
        isA<Song>().having((s) => s.id, 'id', isNot(1)),
      ));
      expect(await storage.songs.getById(1), isNull);
      expect(await storage.folders.getSongIds(1), [2]);
      expect(await db.query('folder_songs', where: 'song_id = 1'), isEmpty);
    });

    test('deleting a missing song records nothing', () async {
      final storage = await launch();
      await storage.songs.delete(12345);
      expect(await tombstones(storage.databaseForTesting), isEmpty);
    });

    test('deleting a folder keeps every song and records the folder', () async {
      await createExistingDatabase(2);
      final storage = await launch();
      final db = storage.databaseForTesting;
      final folderSyncId = (await syncIds(db, 'folders'))[1]!;
      final songsBefore = await rows(db, 'songs');

      await storage.folders.delete(1);

      expect(await rows(db, 'songs'), songsBefore, reason: 'songs untouched');
      expect((await storage.folders.getAll()).map((f) => f.id), [2]);
      expect(await db.query('folder_songs', where: 'folder_id = 1'), isEmpty);
      expect(await storage.folders.getSongIds(2), [3]);
      final t = (await tombstones(db)).single;
      expect(t['entity_type'], TombstoneEntity.folder);
      expect(t['sync_id'], folderSyncId);
    });

    test('removing a song from a folder is recorded; re-adding clears it', () async {
      await createExistingDatabase(2);
      final storage = await launch();
      final db = storage.databaseForTesting;
      final folderSyncId = (await syncIds(db, 'folders'))[1]!;
      final songSyncId = (await syncIds(db, 'songs'))[2]!;

      await storage.folders.removeSong(1, 2);
      expect(await storage.folders.getSongIds(1), [1]);
      final t = (await tombstones(db)).single;
      expect(t['entity_type'], TombstoneEntity.folderSong);
      expect(t['sync_id'], folderSyncId);
      expect(t['related_sync_id'], songSyncId);
      expect(await rows(db, 'songs'), hasLength(3), reason: 'song itself kept');

      // Removing again (not a member) changes nothing.
      await storage.folders.removeSong(1, 2);
      expect(await tombstones(db), hasLength(1));

      await storage.folders.addSong(1, 2);
      expect(await storage.folders.getSongIds(1), unorderedEquals([1, 2]));
      expect(await tombstones(db), isEmpty);
      final row = (await db.query('folder_songs', where: 'folder_id = 1 AND song_id = 2')).single;
      expect(row['sync_updated_at_ms'], isNotNull);

      // Adding an existing member is a no-op that keeps its original row.
      final legacyRow = (await db.query('folder_songs', where: 'folder_id = 1 AND song_id = 1')).single;
      await storage.folders.addSong(1, 1);
      expect((await db.query('folder_songs', where: 'folder_id = 1 AND song_id = 1')).single, legacyRow);
    });

    test('tombstones survive relaunch', () async {
      await createExistingDatabase(2);
      var storage = await launch();
      await storage.songs.delete(3);
      await storage.folders.delete(2);
      final before = await tombstones(storage.databaseForTesting);
      expect(before, hasLength(2));
      storage = await relaunch(storage);
      expect(await tombstones(storage.databaseForTesting), before);
    });
  });

  // ---------------------------------------------------------------------
  // Orphan cleanup is sync-safe.
  // ---------------------------------------------------------------------
  group('orphan cleanup', () {
    test('runs once; later dangling memberships are not deleted on launch', () async {
      await createExistingDatabase(2, withOrphan: true);
      var storage = await launch();
      final db = storage.databaseForTesting;
      expect(await db.query('folder_songs', where: 'song_id = 999'), isEmpty);

      // e.g. a future sync wrote a membership before its song arrived.
      await db.insert('folder_songs', {
        'folder_id': 2,
        'song_id': 5000,
        'added_at': '2026-01-01T00:00:00.000',
      });
      storage = await relaunch(storage);
      expect(
        await storage.databaseForTesting.query('folder_songs', where: 'song_id = 5000'),
        hasLength(1),
      );
      // Still invisible to the UI.
      expect(await storage.folders.getSongIds(2), [3]);
    });

    test('is skipped while a sync batch is marked in progress', () async {
      await createExistingDatabase(2);
      var storage = await launch();
      final db = storage.databaseForTesting;
      // Pretend cleanup never ran, a batch is mid-apply, and a membership
      // arrived ahead of its song.
      await db.delete('sync_meta',
          where: 'key = ?', whereArgs: [SyncMetaKeys.legacyOrphanCleanupDoneAtMs]);
      await writeSyncMeta(db, SyncMetaKeys.syncApplyInProgress, '1');
      await db.insert('folder_songs', {
        'folder_id': 1,
        'song_id': 6000,
        'added_at': '2026-01-01T00:00:00.000',
      });

      storage = await relaunch(storage);
      var current = storage.databaseForTesting;
      expect(await current.query('folder_songs', where: 'song_id = 6000'), hasLength(1));
      expect(await readSyncMeta(current, SyncMetaKeys.legacyOrphanCleanupDoneAtMs), isNull);

      // Once the flag is cleared, the pending one-time cleanup runs.
      await current.delete('sync_meta',
          where: 'key = ?', whereArgs: [SyncMetaKeys.syncApplyInProgress]);
      storage = await relaunch(storage);
      current = storage.databaseForTesting;
      expect(await current.query('folder_songs', where: 'song_id = 6000'), isEmpty);
      expect(await readSyncMeta(current, SyncMetaKeys.legacyOrphanCleanupDoneAtMs), isNotNull);
    });
  });

  // ---------------------------------------------------------------------
  // Backup internals.
  // ---------------------------------------------------------------------
  group('backup', () {
    test('header user_version is read without opening the database', () async {
      await createExistingDatabase(0);
      expect(await readSqliteHeaderUserVersion(dbPath), 0);
      final storage = await launch();
      await storage.close();
      opened.remove(storage);
      expect(await readSqliteHeaderUserVersion(dbPath), kSongbookDatabaseVersion);

      final notSqlite = File(p.join(dbDir, 'not_sqlite.bin'));
      await notSqlite.writeAsString('hello');
      expect(await readSqliteHeaderUserVersion(notSqlite.path), isNull);
      await notSqlite.delete();
    });

    test('rows that only exist in the -wal file are included in the backup', () async {
      // Build a WAL-mode legacy database and capture its files while the
      // last insert is still only in -wal (as after an app kill).
      final stagingDir = await Directory(p.join(dbDir, 'wal_staging')).create(recursive: true);
      final stagingPath = p.join(stagingDir.path, 'songbook.db');
      final db = await databaseFactory.openDatabase(
        stagingPath,
        options: OpenDatabaseOptions(singleInstance: false),
      );
      await db.rawQuery('PRAGMA journal_mode=WAL');
      await db.execute('PRAGMA wal_autocheckpoint=0');
      await db.execute('''
        CREATE TABLE songs (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          karaoke_type TEXT NOT NULL, song_number TEXT NOT NULL,
          title TEXT NOT NULL, artist TEXT, key_type TEXT,
          key_offset INTEGER DEFAULT 0, difficulty TEXT,
          practice_status TEXT, memo TEXT, favorite INTEGER DEFAULT 0,
          created_at TEXT NOT NULL, updated_at TEXT NOT NULL)
      ''');
      await db.insert('songs', _fixtureSongs[0]);
      expect(await File('$stagingPath-wal').exists(), isTrue);
      await File(stagingPath).copy(dbPath);
      await File('$stagingPath-wal').copy('$dbPath-wal');
      await db.close();
      await stagingDir.delete(recursive: true);

      final storage = await launch();
      expect(storage.lastBackupResult!.status, PreMigrationBackupStatus.created);
      expect(await File('$backupPath-wal').exists(), isFalse);

      final backup = await databaseFactory.openDatabase(
        backupPath,
        options: OpenDatabaseOptions(singleInstance: false),
      );
      expect(await rows(backup, 'songs', columns: _legacySongColumns), [_fixtureSongs[0]]);
      await backup.close();
      expect(await rows(storage.databaseForTesting, 'songs', columns: _legacySongColumns),
          [_fixtureSongs[0]]);
    });
  });

  // ---------------------------------------------------------------------
  // Backup metadata recovery (backup written, metadata not yet recorded).
  // ---------------------------------------------------------------------
  group('backup metadata recovery', () {
    Future<int> backupMtimeMs() async =>
        (await File(backupPath).lastModified()).toUtc().millisecondsSinceEpoch;

    for (final fromVersion in [0, 2]) {
      test('app killed after backup but before onOpen (v$fromVersion): '
          'next launch records metadata from the existing file', () async {
        await createExistingDatabase(fromVersion);
        // First launch got only as far as the backup, then the process died:
        // the database itself was never opened.
        final first = await backupBeforeMigrationIfNeeded(
          databasePath: dbPath,
          targetVersion: kSongbookDatabaseVersion,
        );
        expect(first.status, PreMigrationBackupStatus.created);
        final bytes = await File(backupPath).readAsBytes();
        final mtime = await backupMtimeMs();

        final storage = await launch();
        expect(storage.lastBackupResult!.status, PreMigrationBackupStatus.alreadyExists);
        final db = storage.databaseForTesting;
        expect(await readSyncMeta(db, SyncMetaKeys.preSyncBackupFile), preSyncBackupFileName);
        expect(await readSyncMeta(db, SyncMetaKeys.preSyncBackupCreatedAtMs), '$mtime');

        // Backup untouched and still the pre-migration database.
        expect(await File(backupPath).readAsBytes(), bytes);
        expect(await readSqliteHeaderUserVersion(backupPath), fromVersion);
        // User data migrated normally.
        expect(await rows(db, 'songs', columns: _legacySongColumns), _fixtureSongs);
        expect(await syncIds(db, 'songs'), hasLength(_fixtureSongs.length));
      });
    }

    test('migration committed but metadata missing or empty: recovered on relaunch', () async {
      await createExistingDatabase(2);
      var storage = await launch();
      final bytes = await File(backupPath).readAsBytes();
      final mtime = await backupMtimeMs();
      final db = storage.databaseForTesting;
      await db.delete('sync_meta',
          where: 'key = ?', whereArgs: [SyncMetaKeys.preSyncBackupFile]);
      await writeSyncMeta(db, SyncMetaKeys.preSyncBackupCreatedAtMs, '');

      storage = await relaunch(storage);
      final current = storage.databaseForTesting;
      expect(await readSyncMeta(current, SyncMetaKeys.preSyncBackupFile), preSyncBackupFileName);
      expect(await readSyncMeta(current, SyncMetaKeys.preSyncBackupCreatedAtMs), '$mtime');
      expect(await File(backupPath).readAsBytes(), bytes);
      expect(await rows(current, 'songs', columns: _legacySongColumns), _fixtureSongs);
    });

    test('existing metadata is never overwritten', () async {
      await createExistingDatabase(2);
      var storage = await launch();
      final bytes = await File(backupPath).readAsBytes();
      final db = storage.databaseForTesting;
      final recordedName = await readSyncMeta(db, SyncMetaKeys.preSyncBackupFile);
      final recordedAt = await readSyncMeta(db, SyncMetaKeys.preSyncBackupCreatedAtMs);
      expect(recordedName, preSyncBackupFileName);
      expect(recordedAt, isNotNull);

      // Normal relaunches keep the original values (the created time is
      // not replaced by the file's mtime).
      for (var i = 0; i < 2; i++) {
        storage = await relaunch(storage);
        final current = storage.databaseForTesting;
        expect(await readSyncMeta(current, SyncMetaKeys.preSyncBackupFile), recordedName);
        expect(await readSyncMeta(current, SyncMetaKeys.preSyncBackupCreatedAtMs), recordedAt);
      }

      // Any other non-empty value is left as is too.
      await writeSyncMeta(storage.databaseForTesting, SyncMetaKeys.preSyncBackupCreatedAtMs, '12345');
      storage = await relaunch(storage);
      expect(
        await readSyncMeta(storage.databaseForTesting, SyncMetaKeys.preSyncBackupCreatedAtMs),
        '12345',
      );
      expect(await File(backupPath).readAsBytes(), bytes);
    });

    test('no backup file: nothing is recorded', () async {
      final storage = await launch(); // fresh install
      var current = storage.databaseForTesting;
      expect(await readSyncMeta(current, SyncMetaKeys.preSyncBackupFile), isNull);
      final next = await relaunch(storage);
      current = next.databaseForTesting;
      expect(await readSyncMeta(current, SyncMetaKeys.preSyncBackupFile), isNull);
      expect(await readSyncMeta(current, SyncMetaKeys.preSyncBackupCreatedAtMs), isNull);
      expect(await File(backupPath).exists(), isFalse);
    });
  });
}
