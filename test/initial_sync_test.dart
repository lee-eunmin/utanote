import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:utanote/account/account_controller.dart';
import 'package:utanote/account/auth_gateway.dart';
import 'package:utanote/models/folder.dart';
import 'package:utanote/models/song.dart';
import 'package:utanote/storage/android/sqlite_local_storage.dart';
import 'package:utanote/storage/android/sqlite_pre_cloud_backup.dart';
import 'package:utanote/storage/android/sqlite_pre_migration_backup.dart';
import 'package:utanote/storage/android/sqlite_schema.dart';
import 'package:utanote/sync/cloud_sync_backend.dart';
import 'package:utanote/sync/cloud_sync_controller.dart';
import 'package:utanote/sync/initial_sync_engine.dart';
import 'package:utanote/sync/local_sync_store.dart';
import 'package:utanote/sync/sync_records.dart';
import 'package:utanote/ui/widgets/account_button.dart';

import 'support/sync_fakes.dart';

/// Phase B-3: first cloud connection (upload / restore / merge / bind),
/// against real SQLite (sqflite_common_ffi) and a fake cloud backend.

const _uid = 'uid-alice';
const _alice = AccountUser(uid: _uid, email: 'alice@example.com');

// Fixed sync ids so local and cloud can share identities.
const _a = 'a0000000-0000-4000-8000-000000000001';
const _b = 'b0000000-0000-4000-8000-000000000002';
const _c = 'c0000000-0000-4000-8000-000000000003';
const _d = 'd0000000-0000-4000-8000-000000000004';
const _e = 'e0000000-0000-4000-8000-000000000005';
const _f = 'f0000000-0000-4000-8000-000000000006';
const _g = 'a1000000-0000-4000-8000-000000000007';
const _h = 'a2000000-0000-4000-8000-000000000008';
const _i = 'a3000000-0000-4000-8000-000000000009';
const _folderX = 'f1000000-0000-4000-8000-00000000000a';
const _folderY = 'f2000000-0000-4000-8000-00000000000b';

void main() {
  late String dbDir;
  late String dbPath;
  late String cloudBackupPath;
  final opened = <SqliteLocalStorage>[];

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final tempDir =
        await Directory.systemTemp.createTemp('utanote_initial_sync_test_');
    await databaseFactory.setDatabasesPath(tempDir.path);
    dbDir = await databaseFactory.getDatabasesPath();
    dbPath = p.join(dbDir, 'songbook.db');
    cloudBackupPath = p.join(dbDir, preCloudSyncBackupFileName);
  });

  Future<void> wipe() async {
    for (final s in opened) {
      await s.close();
    }
    opened.clear();
    await databaseFactory.deleteDatabase(dbPath);
    final tmp = '$cloudBackupPath.tmp';
    if (await Directory(tmp).exists()) await Directory(tmp).delete();
    for (final path in [
      cloudBackupPath,
      tmp,
      p.join(dbDir, preSyncBackupFileName),
    ]) {
      if (await File(path).exists()) await File(path).delete();
    }
  }

  setUp(wipe);
  tearDown(wipe);

  Future<SqliteLocalStorage> launch() async {
    final s = SqliteLocalStorage();
    await s.init();
    opened.add(s);
    return s;
  }

  Future<SqliteLocalStorage> relaunch(SqliteLocalStorage previous) async {
    await previous.close();
    opened.remove(previous);
    return launch();
  }

  Database dbOf(SqliteLocalStorage s) => s.databaseForTesting;

  InitialSyncEngine engineFor(
    SqliteLocalStorage s,
    FakeCloudBackend cloud, {
    int batchSize = CloudSyncBackend.maxBatchWrites,
  }) =>
      InitialSyncEngine(store: s.syncStore, backend: cloud, batchSize: batchSize);

  final day = DateTime.parse('2024-01-01T00:00:00.000');

  Future<Song> addSong(
    SqliteLocalStorage s,
    String title, {
    String? syncId,
    String number = '100',
    String type = 'TJ',
    String? memo,
    List<String> aliases = const [],
  }) =>
      s.songs.create(Song(
        karaokeType: type,
        songNumber: number,
        title: title,
        memo: memo,
        searchAliases: aliases,
        createdAt: day,
        updatedAt: day,
        syncId: syncId,
      ));

  Future<Folder> addFolder(SqliteLocalStorage s, String name, {String? syncId}) =>
      s.folders.create(
        Folder(name: name, createdAt: day, updatedAt: day, syncId: syncId),
      );

  Future<void> setSongVersion(SqliteLocalStorage s, String syncId, int? ms,
      {String? updatedAt}) async {
    await dbOf(s).update(
      'songs',
      {
        'sync_updated_at_ms': ms,
        'updated_at': ?updatedAt,
      },
      where: 'sync_id = ?',
      whereArgs: [syncId],
    );
  }

  Future<Map<String, Object?>?> songRow(SqliteLocalStorage s, String syncId) async {
    final rows = await dbOf(s)
        .query('songs', where: 'sync_id = ?', whereArgs: [syncId]);
    return rows.isEmpty ? null : rows.first;
  }

  Future<String?> meta(SqliteLocalStorage s, String key) =>
      readSyncMeta(dbOf(s), key);

  Future<List<int>> dirtyFlags(SqliteLocalStorage s, String table) async =>
      [
        for (final r in await dbOf(s).query(table, columns: ['sync_dirty']))
          r['sync_dirty'] as int,
      ];

  /// A typical device: songs (one KY with memo/aliases), a folder with a
  /// member, a removed membership and a deleted song.
  Future<void> seedDevice(SqliteLocalStorage s) async {
    final s1 = await addSong(s, '밤을 달리다',
        type: 'KY', memo: '레거시 메모', aliases: ['요루니카케루'], syncId: _a);
    final s2 = await addSong(s, '아이돌', number: '200', syncId: _b);
    final gone = await addSong(s, '지운곡', number: '300', syncId: _c);
    final folder = await addFolder(s, '애창곡', syncId: _folderX);
    await s.folders.addSong(folder.id!, s1.id!);
    await s.folders.addSong(folder.id!, s2.id!);
    await s.folders.removeSong(folder.id!, s2.id!); // membership tombstone
    await s.songs.delete(gone.id!); // song tombstone
  }

  // -------------------------------------------------------------------------
  group('classification', () {
    test('device has data, cloud empty -> upload', () async {
      final s = await launch();
      await seedDevice(s);
      final a = await engineFor(s, FakeCloudBackend()).assess(_uid);
      expect(a.kind, InitialSyncAssessmentKind.ready);
      expect(a.mode, InitialSyncMode.upload);
    });

    test('device empty, cloud has data -> restore', () async {
      final s = await launch();
      final cloud = FakeCloudBackend()
        ..seed(_uid, CloudDocCodec.putSong(_a, songData('곡'), 1000));
      final a = await engineFor(s, cloud).assess(_uid);
      expect(a.mode, InitialSyncMode.restore);
    });

    test('both empty -> bind only; the run just binds the account', () async {
      final s = await launch();
      final cloud = FakeCloudBackend();
      final engine = engineFor(s, cloud);
      expect((await engine.assess(_uid)).mode, InitialSyncMode.bindOnly);
      final r = await engine.run(_uid, mode: InitialSyncMode.bindOnly);
      expect(r.completed, isTrue);
      expect(cloud.commitCount, 0);
      expect(await meta(s, SyncMetaKeys.accountUid), _uid);
      expect(await meta(s, SyncMetaKeys.initialSyncState), 'done');
    });

    test('both have data -> needs the user, and a run writes nothing', () async {
      final s = await launch();
      await seedDevice(s);
      final cloud = FakeCloudBackend()
        ..seed(_uid, CloudDocCodec.putSong(_g, songData('다른 기기 곡'), 1000));
      final engine = engineFor(s, cloud);
      final a = await engine.assess(_uid);
      expect(a.kind, InitialSyncAssessmentKind.needsMergeDecision);
      expect(a.local.songs, 2);
      expect(a.cloud.songs, 1);

      final before = await dumpUserTables(dbOf(s));
      final metaBefore = await dumpSyncMeta(dbOf(s));
      final r = await engine.run(_uid, mode: InitialSyncMode.upload);
      expect(r.completed, isFalse);
      expect(r.needsDecision, isNotNull);
      expect(cloud.commitCount, 0);
      expect(await dumpUserTables(dbOf(s)), before);
      expect(await dumpSyncMeta(dbOf(s)), metaBefore);
      expect(await File(cloudBackupPath).exists(), isFalse);
    });

    test('only deletions on the device, cloud empty -> upload them', () async {
      final s = await launch();
      final song = await addSong(s, '곧 지움', syncId: _a);
      await s.songs.delete(song.id!);
      final cloud = FakeCloudBackend();
      final engine = engineFor(s, cloud);
      expect((await engine.assess(_uid)).mode, InitialSyncMode.upload);
      await engine.run(_uid, mode: InitialSyncMode.upload);
      expect(cloud.docOf(_uid, 'songs', _a)!['deleted'], isTrue);
      expect(await meta(s, SyncMetaKeys.accountUid), _uid);
    });

    test('device deletions that would remove cloud data -> needs the user',
        () async {
      final s = await launch();
      final song = await addSong(s, '지운 곡', syncId: _a);
      await s.songs.delete(song.id!);
      final cloud = FakeCloudBackend()
        ..seed(_uid, CloudDocCodec.putSong(_a, songData('지운 곡'), 1000));
      final a = await engineFor(s, cloud).assess(_uid);
      expect(a.kind, InitialSyncAssessmentKind.needsMergeDecision);
    });

    test('device deletions unrelated to the cloud data -> restore', () async {
      final s = await launch();
      final song = await addSong(s, '지운 곡', syncId: _a);
      await s.songs.delete(song.id!);
      final cloud = FakeCloudBackend()
        ..seed(_uid, CloudDocCodec.putSong(_b, songData('클라우드 곡'), 1000));
      final a = await engineFor(s, cloud).assess(_uid);
      expect(a.mode, InitialSyncMode.restore);
    });

    test('already bound / bound to another account', () async {
      final s = await launch();
      await writeSyncMeta(dbOf(s), SyncMetaKeys.accountUid, _uid);
      final engine = engineFor(s, FakeCloudBackend());
      expect((await engine.assess(_uid)).kind,
          InitialSyncAssessmentKind.alreadyLinked);
      expect((await engine.assess('uid-bob')).kind,
          InitialSyncAssessmentKind.linkedToOtherAccount);
      await expectLater(
        engine.run('uid-bob', mode: InitialSyncMode.upload),
        throwsA(isA<InitialSyncFailure>()),
      );
      expect(await meta(s, SyncMetaKeys.accountUid), _uid);
    });
  });

  // -------------------------------------------------------------------------
  group('first upload', () {
    test('uploads songs, folders, memberships and deletions, then binds',
        () async {
      final s = await launch();
      await seedDevice(s);
      final cloud = FakeCloudBackend();
      final r = await engineFor(s, cloud)
          .run(_uid, mode: InitialSyncMode.upload, email: 'alice@example.com');
      expect(r.completedMode, InitialSyncMode.upload);

      final a = cloud.docOf(_uid, 'songs', _a)!;
      expect(a['syncId'], _a);
      expect(a['provider'], 'KY');
      expect(a['title'], '밤을 달리다');
      expect(a['memo'], '레거시 메모');
      expect(a['searchAliases'], ['요루니카케루']);
      expect(a['createdAt'], '2024-01-01T00:00:00.000');
      expect(a['deleted'], isFalse);
      expect(a['updatedAtMs'], isA<int>());
      expect(a['serverUpdatedAt'], isNotNull);
      expect(a.keys, isNot(contains('id')));

      expect(cloud.docOf(_uid, 'songs', _c)!['deleted'], isTrue); // tombstone
      expect(cloud.docOf(_uid, 'folders', _folderX)!['name'], '애창곡');
      final live = cloud.docOf(_uid, 'folderSongs', '${_folderX}_$_a')!;
      expect(live['folderSyncId'], _folderX);
      expect(live['songSyncId'], _a);
      expect(live['deleted'], isFalse);
      final removed = cloud.docOf(_uid, 'folderSongs', '${_folderX}_$_b')!;
      expect(removed['deleted'], isTrue);
      expect(removed['deletedAtMs'], isA<int>());

      expect(await meta(s, SyncMetaKeys.accountUid), _uid);
      expect(await meta(s, SyncMetaKeys.accountEmailHint), 'alice@example.com');
      expect(await meta(s, SyncMetaKeys.initialSyncState), 'done');
      expect(await meta(s, SyncMetaKeys.initialSyncMode), 'upload');
      expect(await meta(s, SyncMetaKeys.syncApplyInProgress), isNull);
      for (final t in ['songs', 'folders', 'folder_songs', 'sync_tombstones']) {
        expect(await dirtyFlags(s, t), everyElement(0), reason: t);
      }
    });

    test('local data is never modified by an upload', () async {
      final s = await launch();
      await seedDevice(s);
      List<Map<String, Object?>> strip(List<Map<String, Object?>> rows) =>
          [for (final r in rows) Map.of(r)..remove('sync_dirty')];
      final before = await dumpUserTables(dbOf(s));
      await engineFor(s, FakeCloudBackend())
          .run(_uid, mode: InitialSyncMode.upload);
      final after = await dumpUserTables(dbOf(s));
      for (final t in before.keys) {
        expect(strip(after[t]!), strip(before[t]!), reason: t);
      }
    });

    test('membership document ids are folderSyncId_songSyncId', () async {
      final s = await launch();
      await seedDevice(s);
      final cloud = FakeCloudBackend();
      await engineFor(s, cloud).run(_uid, mode: InitialSyncMode.upload);
      expect(cloud.col(_uid, 'folderSongs').keys.toSet(),
          {'${_folderX}_$_a', '${_folderX}_$_b'});
      expect(membershipDocId(_folderX, _a), '${_folderX}_$_a');
    });

    test('writes go in batches of at most 400', () async {
      final s = await launch();
      final folder = await addFolder(s, '큰 폴더');
      for (var n = 0; n < 450; n++) {
        final song = await addSong(s, '곡 $n', number: '$n');
        await s.folders.addSong(folder.id!, song.id!);
      }
      final cloud = FakeCloudBackend();
      await engineFor(s, cloud).run(_uid, mode: InitialSyncMode.upload);
      expect(cloud.batchSizes, everyElement(lessThanOrEqualTo(400)));
      expect(cloud.batchSizes.fold<int>(0, (a, b) => a + b), 901);
      expect(cloud.docCount(_uid, 'songs'), 450);
      expect(cloud.docCount(_uid, 'folderSongs'), 450);
    });

    test('a row edited during the upload stays dirty; the rest is cleared',
        () async {
      final s = await launch();
      await seedDevice(s);
      final cloud = FakeCloudBackend();
      cloud.beforeCommit = (n) async {
        if (n != 1) return;
        final song = (await s.songs.getAll()).firstWhere((x) => x.syncId == _a);
        await s.songs.update(song.copyWith(title: '업로드 중 수정'));
        await addSong(s, '업로드 중 추가', syncId: _d);
      };
      await engineFor(s, cloud).run(_uid, mode: InitialSyncMode.upload);

      expect((await songRow(s, _a))!['sync_dirty'], 1);
      expect((await songRow(s, _a))!['title'], '업로드 중 수정');
      expect((await songRow(s, _d))!['sync_dirty'], 1);
      expect((await songRow(s, _b))!['sync_dirty'], 0);
      // The cloud has the version that was read before the edit.
      expect(cloud.docOf(_uid, 'songs', _a)!['title'], '밤을 달리다');
      expect(cloud.docOf(_uid, 'songs', _d), isNull);
      expect(await meta(s, SyncMetaKeys.accountUid), _uid);
    });

    test('failure mid-upload: nothing local changes, no binding, retry works',
        () async {
      var s = await launch();
      await seedDevice(s);
      for (var n = 0; n < 5; n++) {
        await addSong(s, '추가 $n', number: '9$n');
      }
      final cloud = FakeCloudBackend()..failOnCommit = 2;
      final before = await dumpUserTables(dbOf(s));

      await expectLater(
        engineFor(s, cloud, batchSize: 3).run(_uid, mode: InitialSyncMode.upload),
        throwsA(isA<InitialSyncFailure>().having(
            (f) => f.kind, 'kind', InitialSyncFailureKind.network)),
      );
      expect(cloud.docCount(_uid, 'songs'), greaterThan(0)); // partial
      expect(await dumpUserTables(dbOf(s)), before);
      expect(await meta(s, SyncMetaKeys.accountUid), isNull);
      expect(await meta(s, SyncMetaKeys.initialSyncState), 'failed');
      expect(await meta(s, SyncMetaKeys.initialSyncMode), 'upload');
      expect(await meta(s, SyncMetaKeys.initialSyncUid), _uid);

      // App restart, then retry: resumes as an upload (no merge prompt)
      // even though the cloud now holds part of the data.
      s = await relaunch(s);
      cloud.failOnCommit = null;
      final engine = engineFor(s, cloud, batchSize: 3);
      final again = await engine.assess(_uid);
      expect(again.kind, InitialSyncAssessmentKind.ready);
      expect(again.mode, InitialSyncMode.upload);
      await engine.run(_uid, mode: InitialSyncMode.upload);

      // Deterministic ids: exactly one document per local row/tombstone.
      expect(cloud.docCount(_uid, 'songs'), 2 + 5 + 1);
      expect(cloud.docCount(_uid, 'folders'), 1);
      expect(cloud.docCount(_uid, 'folderSongs'), 2);
      expect(await meta(s, SyncMetaKeys.accountUid), _uid);
      expect(await dirtyFlags(s, 'songs'), everyElement(0));
    });

    test('app killed mid-upload (state left in_progress) can resume', () async {
      var s = await launch();
      await seedDevice(s);
      final cloud = FakeCloudBackend();
      // What a kill after the first batch leaves behind.
      await s.syncStore.markInitialSyncStarted(_uid, 'upload');
      cloud.seed(_uid, CloudDocCodec.putSong(_a, songData('밤을 달리다'), 1));
      s = await relaunch(s);

      expect(await meta(s, SyncMetaKeys.initialSyncState), 'in_progress');
      expect(await meta(s, SyncMetaKeys.accountUid), isNull);
      final engine = engineFor(s, cloud);
      expect((await engine.assess(_uid)).mode, InitialSyncMode.upload);
      await engine.run(_uid, mode: InitialSyncMode.upload);
      expect(await meta(s, SyncMetaKeys.accountUid), _uid);
      expect(cloud.docOf(_uid, 'songs', _a)!['provider'], 'KY');
    });

    test('a resume does not swallow data from another device', () async {
      final s = await launch();
      await seedDevice(s);
      await s.syncStore.markInitialSyncStarted(_uid, 'upload');
      final cloud = FakeCloudBackend()
        ..seed(_uid, CloudDocCodec.putSong(_g, songData('다른 기기'), 1));
      expect((await engineFor(s, cloud).assess(_uid)).kind,
          InitialSyncAssessmentKind.needsMergeDecision);
    });

    test('cloud read failure: nothing written anywhere', () async {
      final s = await launch();
      await seedDevice(s);
      final cloud = FakeCloudBackend()
        ..fetchError = const CloudSyncBackendException(
            CloudSyncErrorKind.network, 'offline');
      final before = await dumpUserTables(dbOf(s));
      await expectLater(
        engineFor(s, cloud).run(_uid, mode: InitialSyncMode.upload),
        throwsA(isA<InitialSyncFailure>()),
      );
      expect(await dumpUserTables(dbOf(s)), before);
      expect(await meta(s, SyncMetaKeys.accountUid), isNull);
      expect(await meta(s, SyncMetaKeys.initialSyncState), isNull);
      expect(cloud.commitCount, 0);
    });

    test('permission denied is reported as such', () async {
      final s = await launch();
      await seedDevice(s);
      final cloud = FakeCloudBackend()
        ..failOnCommit = 1
        ..commitError = const CloudSyncBackendException(
            CloudSyncErrorKind.permissionDenied, 'denied');
      await expectLater(
        engineFor(s, cloud).run(_uid, mode: InitialSyncMode.upload),
        throwsA(isA<InitialSyncFailure>().having((f) => f.kind, 'kind',
            InitialSyncFailureKind.permissionDenied)),
      );
      expect(await meta(s, SyncMetaKeys.accountUid), isNull);
    });
  });

  // -------------------------------------------------------------------------
  group('restore', () {
    FakeCloudBackend cloudWithData() => FakeCloudBackend()
      ..seed(_uid, CloudDocCodec.putSong(_a, songData('복원곡', number: '1'), 1000))
      ..seed(_uid, CloudDocCodec.putSong(_b, songData('삭제된곡'), 1000))
      ..seed(_uid, CloudDocCodec.deleteSong(_b, 2000))
      ..seed(_uid, CloudDocCodec.putFolder(_folderX, folderData('복원폴더'), 1000))
      ..seed(_uid, CloudDocCodec.putFolder(_folderY, folderData('삭제폴더'), 1000))
      ..seed(_uid, CloudDocCodec.deleteFolder(_folderY, 2000))
      ..seed(_uid, CloudDocCodec.putMembership(
          _folderX, _a, '2024-01-02T00:00:00.000', 1000, revision: 1))
      // parent song deleted
      ..seed(_uid, CloudDocCodec.putMembership(
          _folderX, _b, '2024-01-02T00:00:00.000', 1000, revision: 1))
      // parent song doesn't exist anywhere
      ..seed(_uid, CloudDocCodec.putMembership(
          _folderX, _c, '2024-01-02T00:00:00.000', 1000, revision: 1))
      // parent folder deleted
      ..seed(_uid, CloudDocCodec.putMembership(
          _folderY, _a, '2024-01-02T00:00:00.000', 1000, revision: 1));

    test('restores live data clean; deleted and orphaned data is not restored',
        () async {
      final s = await launch();
      final cloud = cloudWithData();
      final r = await engineFor(s, cloud).run(_uid, mode: InitialSyncMode.restore);
      expect(r.completedMode, InitialSyncMode.restore);

      final songs = await s.songs.getAll();
      expect(songs.map((x) => x.syncId), [_a]);
      expect(songs.single.title, '복원곡');
      final folders = await s.folders.getAll();
      expect(folders.map((x) => x.syncId), [_folderX]);
      expect(await s.folders.getSongIds(folders.single.id!), [songs.single.id]);
      expect((await dbOf(s).query('folder_songs')).length, 1);

      // Deletions are recorded so they keep winning later.
      final tombstones = await dbOf(s).query('sync_tombstones');
      expect(
        {for (final t in tombstones) '${t['entity_type']}:${t['sync_id']}'},
        containsAll(['song:$_b', 'folder:$_folderY']),
      );
      for (final t in ['songs', 'folders', 'folder_songs', 'sync_tombstones']) {
        expect(await dirtyFlags(s, t), everyElement(0), reason: t);
      }
      expect((await songRow(s, _a))!['sync_updated_at_ms'], 1000);
      expect(await meta(s, SyncMetaKeys.accountUid), _uid);
      expect(await meta(s, SyncMetaKeys.syncApplyInProgress), isNull);

      // Dangling cloud memberships are marked deleted, never revived.
      for (final key in ['${_folderX}_$_b', '${_folderX}_$_c', '${_folderY}_$_a']) {
        expect(cloud.docOf(_uid, 'folderSongs', key)!['deleted'], isTrue,
            reason: key);
      }
      expect(cloud.docOf(_uid, 'folderSongs', '${_folderX}_$_a')!['deleted'],
          isFalse);
      expect(cloud.docOf(_uid, 'songs', _b)!['deleted'], isTrue);
    });

    test('failure before the local apply: device untouched and unbound',
        () async {
      final s = await launch();
      final cloud = cloudWithData()..failOnCommit = 1;
      await expectLater(
        engineFor(s, cloud).run(_uid, mode: InitialSyncMode.restore),
        throwsA(isA<InitialSyncFailure>()),
      );
      expect(await s.songs.getAll(), isEmpty);
      expect(await s.folders.getAll(), isEmpty);
      expect(await dbOf(s).query('sync_tombstones'), isEmpty);
      expect(await meta(s, SyncMetaKeys.accountUid), isNull);
      expect(await meta(s, SyncMetaKeys.initialSyncState), 'failed');
    });
  });

  // -------------------------------------------------------------------------
  group('merge', () {
    test('cancel changes nothing anywhere', () async {
      final s = await launch();
      await seedDevice(s);
      final cloud = FakeCloudBackend()
        ..seed(_uid, CloudDocCodec.putSong(_g, songData('클라우드 곡'), 1000));
      final cloudBefore = cloud.col(_uid, 'songs').toString();
      final before = await dumpUserTables(dbOf(s));
      final metaBefore = await dumpSyncMeta(dbOf(s));

      final account = AccountController(
        gateway: FakeAuth(_alice),
        boundAccount: _Bound(s),
      );
      await account.start();
      await account.signIn();
      final sync = CloudSyncController(
        engine: engineFor(s, cloud),
        account: account,
      );
      await sync.startSetup();
      expect(sync.phase, CloudSyncPhase.needsMergeDecision);
      sync.cancelMerge();
      expect(sync.phase, CloudSyncPhase.notConnected);

      expect(await dumpUserTables(dbOf(s)), before);
      expect(await dumpSyncMeta(dbOf(s)), metaBefore);
      expect(cloud.col(_uid, 'songs').toString(), cloudBefore);
      expect(cloud.commitCount, 0);
      expect(await File(cloudBackupPath).exists(), isFalse);
      expect(await meta(s, SyncMetaKeys.accountUid), isNull);
      sync.dispose();
    });

    test('newer wins, tie goes to the cloud, deletion always wins, '
        'different ids are both kept', () async {
      final s = await launch();
      final cloud = FakeCloudBackend();

      // A: local newer -> local wins.
      await addSong(s, 'A 로컬 최신', syncId: _a);
      await setSongVersion(s, _a, 2000);
      cloud.seed(_uid, CloudDocCodec.putSong(_a, songData('A 클라우드 옛날'), 1000));
      // B: cloud newer -> cloud wins.
      await addSong(s, 'B 로컬 옛날', syncId: _b);
      await setSongVersion(s, _b, 1000);
      cloud.seed(_uid, CloudDocCodec.putSong(_b, songData('B 클라우드 최신'), 2000));
      // C: same time -> cloud wins.
      await addSong(s, 'C 로컬', syncId: _c);
      await setSongVersion(s, _c, 1500);
      cloud.seed(_uid, CloudDocCodec.putSong(_c, songData('C 클라우드'), 1500));
      // D: deleted locally, edited later in the cloud -> deleted.
      final d = await addSong(s, 'D', syncId: _d);
      await s.songs.delete(d.id!);
      cloud.seed(_uid,
          CloudDocCodec.putSong(_d, songData('D 클라우드 수정'), 9999999999999));
      // E: deleted in the cloud, edited later locally -> deleted.
      await addSong(s, 'E 로컬 수정', syncId: _e);
      await setSongVersion(s, _e, 9999999999999);
      cloud.seed(_uid, CloudDocCodec.putSong(_e, songData('E'), 1000));
      cloud.seed(_uid, CloudDocCodec.deleteSong(_e, 1100));
      // F (device) and G (cloud): same title/number, different ids.
      await addSong(s, '같은 노래', number: '777', syncId: _f);
      cloud.seed(_uid,
          CloudDocCodec.putSong(_g, songData('같은 노래', number: '777'), 1000));
      // H: legacy row (no sync time) whose updated_at is newer.
      await addSong(s, 'H 로컬', syncId: _h);
      await setSongVersion(s, _h, null, updatedAt: '2030-01-01T00:00:00.000');
      cloud.seed(_uid, CloudDocCodec.putSong(_h, songData('H 클라우드'),
          DateTime.utc(2025).millisecondsSinceEpoch));
      // I: legacy row whose updated_at is older.
      await addSong(s, 'I 로컬', syncId: _i);
      await setSongVersion(s, _i, null, updatedAt: '2001-01-01T00:00:00.000');
      cloud.seed(_uid, CloudDocCodec.putSong(_i, songData('I 클라우드'),
          DateTime.utc(2025).millisecondsSinceEpoch));

      final engine = engineFor(s, cloud);
      expect((await engine.assess(_uid)).kind,
          InitialSyncAssessmentKind.needsMergeDecision);
      final r = await engine.run(_uid, mode: InitialSyncMode.merge);
      expect(r.completedMode, InitialSyncMode.merge);

      expect(cloud.docOf(_uid, 'songs', _a)!['title'], 'A 로컬 최신');
      expect(cloud.docOf(_uid, 'songs', _a)!['updatedAtMs'], 2000);
      expect((await songRow(s, _a))!['title'], 'A 로컬 최신');

      expect((await songRow(s, _b))!['title'], 'B 클라우드 최신');
      expect((await songRow(s, _b))!['sync_updated_at_ms'], 2000);
      expect(cloud.docOf(_uid, 'songs', _b)!['title'], 'B 클라우드 최신');

      expect((await songRow(s, _c))!['title'], 'C 클라우드');
      expect(cloud.docOf(_uid, 'songs', _c)!['title'], 'C 클라우드');

      expect(await songRow(s, _d), isNull);
      expect(cloud.docOf(_uid, 'songs', _d)!['deleted'], isTrue);

      expect(await songRow(s, _e), isNull);
      expect(cloud.docOf(_uid, 'songs', _e)!['deleted'], isTrue);
      final eTomb = await dbOf(s).query('sync_tombstones',
          where: 'sync_id = ?', whereArgs: [_e]);
      expect(eTomb.single['sync_dirty'], 0);

      expect(await songRow(s, _f), isNotNull);
      expect(await songRow(s, _g), isNotNull);
      expect(cloud.docOf(_uid, 'songs', _f)!['deleted'], isFalse);
      expect(cloud.docOf(_uid, 'songs', _g)!['deleted'], isFalse);

      expect(cloud.docOf(_uid, 'songs', _h)!['title'], 'H 로컬');
      expect((await songRow(s, _i))!['title'], 'I 클라우드');

      for (final t in ['songs', 'folders', 'folder_songs', 'sync_tombstones']) {
        expect(await dirtyFlags(s, t), everyElement(0), reason: t);
      }
      expect(await meta(s, SyncMetaKeys.accountUid), _uid);
      expect(await meta(s, SyncMetaKeys.initialSyncMode), 'merge');
    });

    test('memberships merge by id; a deleted song takes its memberships',
        () async {
      final s = await launch();
      final cloud = FakeCloudBackend();
      final folder = await addFolder(s, '폴더', syncId: _folderX);
      final a = await addSong(s, 'A', syncId: _a);
      await s.folders.addSong(folder.id!, a.id!);
      final d = await addSong(s, 'D', syncId: _d);
      await s.songs.delete(d.id!);

      cloud
        ..seed(_uid, CloudDocCodec.putFolder(_folderX, folderData('폴더'), 1))
        ..seed(_uid, CloudDocCodec.putSong(_g, songData('G'), 1))
        ..seed(_uid, CloudDocCodec.putSong(_d, songData('D'), 1))
        ..seed(_uid, CloudDocCodec.putMembership(
            _folderX, _g, '2024-01-01T00:00:00.000', 1, revision: 1))
        ..seed(_uid, CloudDocCodec.putMembership(
            _folderX, _d, '2024-01-01T00:00:00.000', 1, revision: 1));

      await engineFor(s, cloud).run(_uid, mode: InitialSyncMode.merge);

      final members = await s.folders.getSongIds(folder.id!);
      final memberSyncIds = {
        for (final id in members) (await s.songs.getById(id))!.syncId,
      };
      expect(memberSyncIds, {_a, _g});
      expect(cloud.docOf(_uid, 'folderSongs', '${_folderX}_$_a')!['deleted'],
          isFalse);
      expect(cloud.docOf(_uid, 'folderSongs', '${_folderX}_$_g')!['deleted'],
          isFalse);
      expect(cloud.docOf(_uid, 'folderSongs', '${_folderX}_$_d')!['deleted'],
          isTrue);
      expect(cloud.docOf(_uid, 'songs', _d)!['deleted'], isTrue);
      // The same folder was not duplicated.
      expect((await s.folders.getAll()).length, 1);
      expect(cloud.docCount(_uid, 'folders'), 1);
    });

    test('a cloud-winning row edited during the upload keeps the edit',
        () async {
      final s = await launch();
      await addSong(s, 'B 로컬', syncId: _b);
      await setSongVersion(s, _b, 1000);
      await addSong(s, 'A 로컬 신규', syncId: _a);
      final cloud = FakeCloudBackend()
        ..seed(_uid, CloudDocCodec.putSong(_b, songData('B 클라우드'), 2000));
      cloud.beforeCommit = (n) async {
        final b = (await s.songs.getAll()).firstWhere((x) => x.syncId == _b);
        await s.songs.update(b.copyWith(title: 'B 사용자가 방금 수정'));
      };
      await engineFor(s, cloud).run(_uid, mode: InitialSyncMode.merge);
      expect((await songRow(s, _b))!['title'], 'B 사용자가 방금 수정');
      expect((await songRow(s, _b))!['sync_dirty'], 1);
      expect(await meta(s, SyncMetaKeys.accountUid), _uid);
    });

    test('never writes a cloud-deleted document back as live', () async {
      final s = await launch();
      // Device still has the song (and a folder membership) that another
      // device deleted; local edit is even newer.
      final folder = await addFolder(s, '폴더', syncId: _folderX);
      final a = await addSong(s, 'A', syncId: _a);
      await s.folders.addSong(folder.id!, a.id!);
      await setSongVersion(s, _a, 9999999999999);
      final cloud = FakeCloudBackend()
        ..seed(_uid, CloudDocCodec.putSong(_a, songData('A'), 1))
        ..seed(_uid, CloudDocCodec.deleteSong(_a, 2))
        ..seed(_uid, CloudDocCodec.putFolder(_folderX, folderData('폴더'), 1));
      // The fake rejects any revive (like the security rules), so success
      // proves the engine never tried.
      await engineFor(s, cloud).run(_uid, mode: InitialSyncMode.merge);
      expect(cloud.docOf(_uid, 'songs', _a)!['deleted'], isTrue);
      expect(await songRow(s, _a), isNull);
      expect(await s.folders.getSongIds(folder.id!), isEmpty);
    });
  });

  // -------------------------------------------------------------------------
  group('pre-cloud-sync backup', () {
    test('made once before the first connection, never overwritten', () async {
      final s = await launch();
      await seedDevice(s);
      await engineFor(s, FakeCloudBackend())
          .run(_uid, mode: InitialSyncMode.upload);
      expect(await File(cloudBackupPath).exists(), isTrue);
      expect(await meta(s, SyncMetaKeys.preCloudSyncBackupFile),
          preCloudSyncBackupFileName);

      Future<int> backupSongCount() async {
        final b = await databaseFactory.openDatabase(cloudBackupPath,
            options: OpenDatabaseOptions(readOnly: true, singleInstance: false));
        try {
          return (await b.query('songs')).length;
        } finally {
          await b.close();
        }
      }

      expect(await backupSongCount(), 2);
      await addSong(s, '나중 곡', number: '999');
      final again = await s.syncStore.ensurePreCloudBackup();
      expect(again.status, PreCloudBackupStatus.alreadyExists);
      expect(await backupSongCount(), 2);
    });

    test('backup failure: sync does not start at all', () async {
      final s = await launch();
      await seedDevice(s);
      // A directory where the temp copy must go makes the copy fail.
      await Directory('$cloudBackupPath.tmp').create();
      final cloud = FakeCloudBackend();
      final before = await dumpUserTables(dbOf(s));

      await expectLater(
        engineFor(s, cloud).run(_uid, mode: InitialSyncMode.upload),
        throwsA(isA<InitialSyncFailure>()
            .having((f) => f.kind, 'kind', InitialSyncFailureKind.backup)),
      );
      expect(cloud.commitCount, 0);
      expect(await File(cloudBackupPath).exists(), isFalse);
      expect(await dumpUserTables(dbOf(s)), before);
      expect(await meta(s, SyncMetaKeys.accountUid), isNull);
      expect(await meta(s, SyncMetaKeys.initialSyncState), isNull);
      // The live database is still fine.
      expect((await s.songs.getAll()).length, 2);
    });

    test('the pre-v3 backup is left exactly as it was', () async {
      final s = await launch();
      await seedDevice(s);
      final v3 = File(p.join(dbDir, preSyncBackupFileName));
      await v3.writeAsBytes([1, 2, 3, 4, 5]);
      await engineFor(s, FakeCloudBackend())
          .run(_uid, mode: InitialSyncMode.upload);
      expect(await v3.readAsBytes(), [1, 2, 3, 4, 5]);
    });
  });

  // -------------------------------------------------------------------------
  group('guarded dirty clear', () {
    test('clears only rows still at the recorded version', () async {
      final s = await launch();
      final a = await addSong(s, 'A', syncId: _a);
      await addSong(s, 'B', syncId: _b);
      final versionA = (await songRow(s, _a))!['sync_updated_at_ms'] as int;
      final versionB = (await songRow(s, _b))!['sync_updated_at_ms'] as int;

      // A is edited after its token was taken.
      await setSongVersion(s, _a, versionA + 5);
      final n = await s.syncStore.clearSyncDirtyIfUnchanged([
        SyncDirtyToken.song(_a, versionA),
        SyncDirtyToken.song(_b, versionB),
      ]);
      expect(n, 1);
      expect((await songRow(s, _a))!['sync_dirty'], 1);
      expect((await songRow(s, _b))!['sync_dirty'], 0);
      expect(a.id, isNotNull);
    });

    test('a legacy row without a sync time matches a NULL token', () async {
      final s = await launch();
      await addSong(s, 'A', syncId: _a);
      await setSongVersion(s, _a, null);
      expect(
        await s.syncStore.clearSyncDirtyIfUnchanged(
            [SyncDirtyToken.song(_a, null)]),
        1,
      );
      expect((await songRow(s, _a))!['sync_dirty'], 0);
    });

    test('memberships, folders and tombstones', () async {
      final s = await launch();
      final folder = await addFolder(s, 'X', syncId: _folderX);
      final a = await addSong(s, 'A', syncId: _a);
      await s.folders.addSong(folder.id!, a.id!);
      final gone = await addSong(s, 'C', syncId: _c);
      await s.songs.delete(gone.id!);
      final db = dbOf(s);
      final fsVersion = (await db.query('folder_songs')).single['sync_updated_at_ms'] as int;
      final folderVersion = (await db.query('folders')).single['sync_updated_at_ms'] as int;
      final tomb = (await db.query('sync_tombstones')).single;

      expect(
        await s.syncStore.clearSyncDirtyIfUnchanged([
          SyncDirtyToken.membership(_folderX, _a, fsVersion),
          SyncDirtyToken.folder(_folderX, folderVersion),
          SyncDirtyToken.tombstone(LocalTombstone(
            entityType: tomb['entity_type'] as String,
            syncId: _c,
            relatedSyncId: '',
            deletedAtMs: (tomb['deleted_at_ms'] as int) + 1, // stale
            dirty: true,
          )),
        ]),
        2,
      );
      expect(await dirtyFlags(s, 'folder_songs'), [0]);
      expect(await dirtyFlags(s, 'folders'), [0]);
      expect(await dirtyFlags(s, 'sync_tombstones'), [1]);
      expect(
        await s.syncStore.clearSyncDirtyIfUnchanged([
          SyncDirtyToken.tombstone(LocalTombstone(
            entityType: tomb['entity_type'] as String,
            syncId: _c,
            relatedSyncId: '',
            deletedAtMs: tomb['deleted_at_ms'] as int,
            dirty: true,
          )),
        ]),
        1,
      );
      expect(await dirtyFlags(s, 'sync_tombstones'), [0]);
    });
  });

  // -------------------------------------------------------------------------
  group('account binding', () {
    test('sign-out keeps account_uid; the same account is recognised again',
        () async {
      final s = await launch();
      await seedDevice(s);
      final account = AccountController(
        gateway: FakeAuth(_alice),
        boundAccount: _Bound(s),
      );
      await account.start();
      await account.signIn();
      expect(account.linkStatus, AccountLinkStatus.unlinked);
      final sync = CloudSyncController(
        engine: engineFor(s, FakeCloudBackend()),
        account: account,
      );
      await sync.startSetup();
      expect(sync.phase, CloudSyncPhase.connected);
      expect(account.linkStatus, AccountLinkStatus.sameAccount);

      await account.signOut();
      expect(await meta(s, SyncMetaKeys.accountUid), _uid);
      expect(sync.phase, CloudSyncPhase.unavailable);

      await account.signIn();
      expect(account.linkStatus, AccountLinkStatus.sameAccount);
      expect(sync.phase, CloudSyncPhase.connected);
      sync.dispose();
    });
  });

  // -------------------------------------------------------------------------
  group('controller', () {
    Future<(AccountController, CloudSyncController)> setUpController(
      SqliteLocalStorage s,
      FakeCloudBackend cloud,
    ) async {
      final account = AccountController(
        gateway: FakeAuth(_alice),
        boundAccount: _Bound(s),
      );
      await account.start();
      await account.signIn();
      final sync = CloudSyncController(
        engine: engineFor(s, cloud),
        account: account,
      );
      return (account, sync);
    }

    test('signed out: unavailable; signed in & unbound: not connected',
        () async {
      final s = await launch();
      final account = AccountController(
        gateway: FakeAuth(_alice),
        boundAccount: _Bound(s),
      );
      final sync = CloudSyncController(
        engine: engineFor(s, FakeCloudBackend()),
        account: account,
      );
      expect(sync.phase, CloudSyncPhase.unavailable);
      await account.start();
      await account.signIn();
      expect(sync.phase, CloudSyncPhase.notConnected);
      sync.dispose();
    });

    test('a second tap while running is ignored', () async {
      final s = await launch();
      await seedDevice(s);
      final cloud = FakeCloudBackend()..fetchGate = Completer<void>();
      final (_, sync) = await setUpController(s, cloud);
      final first = sync.startSetup();
      final second = sync.startSetup();
      expect(sync.busy, isTrue);
      expect(sync.phase, CloudSyncPhase.checking);
      cloud.fetchGate!.complete();
      await Future.wait([first, second]);
      expect(cloud.fetchCount, 2); // one assess + one run, from one tap
      expect(sync.phase, CloudSyncPhase.connected);
      sync.dispose();
    });

    test('failure shows a message and keeps local data; retry succeeds',
        () async {
      final s = await launch();
      await seedDevice(s);
      final cloud = FakeCloudBackend()..failOnCommit = 1;
      final (account, sync) = await setUpController(s, cloud);
      final before = await dumpUserTables(dbOf(s));
      await sync.startSetup();
      expect(sync.phase, CloudSyncPhase.failed);
      expect(sync.message, contains('그대로'));
      expect(await dumpUserTables(dbOf(s)), before);
      expect(account.linkStatus, AccountLinkStatus.unlinked);

      cloud.failOnCommit = null;
      await sync.startSetup();
      expect(sync.phase, CloudSyncPhase.connected);
      expect(account.linkStatus, AccountLinkStatus.sameAccount);
      sync.dispose();
    });

    test('merge chosen by the user', () async {
      final s = await launch();
      await seedDevice(s);
      final cloud = FakeCloudBackend()
        ..seed(_uid, CloudDocCodec.putSong(_g, songData('클라우드 곡'), 1000));
      final (_, sync) = await setUpController(s, cloud);
      await sync.startSetup();
      expect(sync.phase, CloudSyncPhase.needsMergeDecision);
      expect(sync.localSummary!.songs, 2);
      expect(sync.cloudSummary!.songs, 1);
      final version = sync.dataVersion;
      await sync.confirmMerge();
      expect(sync.phase, CloudSyncPhase.connected);
      expect(sync.dataVersion, version + 1);
      expect(await songRow(s, _g), isNotNull);
      expect(cloud.docOf(_uid, 'songs', _a), isNotNull);
      sync.dispose();
    });
  });

  // -------------------------------------------------------------------------
  group('account sheet UI', () {
    Future<(AccountController, CloudSyncController)> controllerFor(
      WidgetTester tester,
      SqliteLocalStorage s,
      FakeCloudBackend cloud,
    ) async {
      final account = AccountController(
        gateway: FakeAuth(_alice),
        boundAccount: _Bound(s),
      );
      await tester.runAsync(() async {
        await account.start();
        await account.signIn();
      });
      final sync = CloudSyncController(
        engine: engineFor(s, cloud),
        account: account,
      );
      account.cloudSync = sync;
      return (account, sync);
    }

    Future<void> showSheet(WidgetTester tester, AccountController account) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: AccountSheet(account: account)),
      ));
      await tester.pump();
    }

    testWidgets('backup setup button, then "백업 연결됨"', (tester) async {
      late SqliteLocalStorage s;
      await tester.runAsync(() async {
        s = await launch();
        await seedDevice(s);
      });
      final (account, sync) = await controllerFor(tester, s, FakeCloudBackend());
      await showSheet(tester, account);
      expect(find.text('클라우드 백업 설정'), findsOneWidget);

      await tester.runAsync(sync.startSetup);
      await tester.pump();
      expect(find.text('백업 연결됨'), findsOneWidget);
      expect(find.text('클라우드 백업 설정'), findsNothing);
      sync.dispose();
    });

    testWidgets('both sides have data: explanation with 합치기 / 취소',
        (tester) async {
      late SqliteLocalStorage s;
      await tester.runAsync(() async {
        s = await launch();
        await seedDevice(s);
      });
      final cloud = FakeCloudBackend()
        ..seed(_uid, CloudDocCodec.putSong(_g, songData('클라우드 곡'), 1000));
      final (account, sync) = await controllerFor(tester, s, cloud);
      await showSheet(tester, account);
      await tester.runAsync(sync.startSetup);
      await tester.pump();
      expect(find.byKey(const Key('cloudMergeConfirm')), findsOneWidget);
      expect(find.byKey(const Key('cloudMergeCancel')), findsOneWidget);
      expect(find.textContaining('노래 2곡'), findsOneWidget);
      expect(find.textContaining('노래 1곡'), findsOneWidget);
      // No other way to resolve it is offered.
      expect(find.textContaining('덮어쓰기'), findsNothing);

      await tester.tap(find.byKey(const Key('cloudMergeCancel')));
      await tester.pump();
      expect(find.text('클라우드 백업 설정'), findsOneWidget);
      expect(cloud.commitCount, 0);
      sync.dispose();
    });

    testWidgets('failure shows the message and a retry button', (tester) async {
      late SqliteLocalStorage s;
      await tester.runAsync(() async {
        s = await launch();
        await seedDevice(s);
      });
      final cloud = FakeCloudBackend()
        ..fetchError = const CloudSyncBackendException(
            CloudSyncErrorKind.network, 'offline');
      final (account, sync) = await controllerFor(tester, s, cloud);
      await showSheet(tester, account);
      await tester.runAsync(sync.startSetup);
      await tester.pump();
      expect(find.byKey(const Key('cloudSyncMessage')), findsOneWidget);
      expect(find.textContaining('네트워크'), findsOneWidget);
      expect(find.byKey(const Key('cloudRetryButton')), findsOneWidget);
      sync.dispose();
    });
  });
}

class _Bound implements BoundAccountSource {
  final SqliteLocalStorage storage;
  _Bound(this.storage);

  @override
  Future<String?> readBoundAccountUid() => storage.readBoundAccountUid();
}
