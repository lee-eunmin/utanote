import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:utanote/account/account_controller.dart';
import 'package:utanote/account/auth_gateway.dart';
import 'package:utanote/main.dart';
import 'package:utanote/models/folder.dart';
import 'package:utanote/models/song.dart';
import 'package:utanote/storage/android/sqlite_local_storage.dart';
import 'package:utanote/storage/android/sqlite_schema.dart';
import 'package:utanote/storage/memory/in_memory_local_storage.dart';
import 'package:utanote/sync/cloud_sync_backend.dart';
import 'package:utanote/sync/cloud_sync_controller.dart';
import 'package:utanote/sync/initial_sync_engine.dart';
import 'package:utanote/sync/local_sync_store.dart';
import 'package:utanote/sync/manual_sync.dart';
import 'package:utanote/ui/widgets/account_button.dart';

import 'support/sync_fakes.dart';

/// Phase B-4A: manual two-way incremental sync ("지금 동기화") between
/// devices that are already bound to the same account. Each "device" is a
/// real SQLite database (sqflite_common_ffi) in its own directory; the
/// cloud is the shared fake backend.

const _uid = 'uid-alice';
const _alice = AccountUser(uid: _uid, email: 'alice@example.com');

void main() {
  late Directory root;
  var deviceCounter = 0;
  final opened = <SqliteLocalStorage>[];

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    root = await Directory.systemTemp.createTemp('utanote_manual_sync_test_');
  });

  tearDown(() async {
    for (final s in opened) {
      await s.close();
    }
    opened.clear();
  });

  /// A device with its own songbook.db.
  Future<SqliteLocalStorage> device() async {
    final dir = p.join(root.path, 'device_${deviceCounter++}');
    await Directory(dir).create(recursive: true);
    await databaseFactory.setDatabasesPath(dir);
    final s = SqliteLocalStorage();
    await s.init();
    opened.add(s);
    return s;
  }

  Database dbOf(SqliteLocalStorage s) => s.databaseForTesting;

  ManualSyncEngine manual(
    SqliteLocalStorage s,
    FakeCloudBackend cloud, {
    int batchSize = CloudSyncBackend.maxBatchWrites,
  }) =>
      ManualSyncEngine(store: s.syncStore, backend: cloud, batchSize: batchSize);

  Future<void> sync(SqliteLocalStorage s, FakeCloudBackend cloud) =>
      manual(s, cloud).syncNow(_uid);

  final day = DateTime.parse('2024-01-01T00:00:00.000');

  Future<Song> addSong(SqliteLocalStorage s, String title,
          {String number = '100'}) =>
      s.songs.create(Song(
        karaokeType: 'TJ',
        songNumber: number,
        title: title,
        createdAt: day,
        updatedAt: day,
      ));

  Future<Folder> addFolder(SqliteLocalStorage s, String name) => s.folders
      .create(Folder(name: name, createdAt: day, updatedAt: day));

  Future<Song?> songBySyncId(SqliteLocalStorage s, String syncId) async {
    final rows = await dbOf(s)
        .query('songs', where: 'sync_id = ?', whereArgs: [syncId]);
    return rows.isEmpty ? null : Song.fromDbMap(rows.first);
  }

  Future<Map<String, Object?>?> songRow(SqliteLocalStorage s, String syncId) async {
    final rows = await dbOf(s)
        .query('songs', where: 'sync_id = ?', whereArgs: [syncId]);
    return rows.isEmpty ? null : rows.first;
  }

  Future<Folder?> folderBySyncId(SqliteLocalStorage s, String syncId) async {
    final rows = await dbOf(s)
        .query('folders', where: 'sync_id = ?', whereArgs: [syncId]);
    return rows.isEmpty ? null : Folder.fromDbMap(rows.first);
  }

  /// Edits a song through the repository (dirty), then pins its change
  /// time so tests control which side is "newer".
  Future<void> editSong(SqliteLocalStorage s, String syncId, String title,
      {required int atMs}) async {
    final song = (await songBySyncId(s, syncId))!;
    await s.songs.update(song.copyWith(title: title));
    await dbOf(s).update('songs', {'sync_updated_at_ms': atMs},
        where: 'sync_id = ?', whereArgs: [syncId]);
  }

  Future<Set<String>> memberSyncIds(SqliteLocalStorage s, String folderSyncId) async {
    final folder = (await folderBySyncId(s, folderSyncId))!;
    final ids = await s.folders.getSongIds(folder.id!);
    return {for (final id in ids) (await s.songs.getById(id))!.syncId!};
  }

  Future<List<int>> dirtyFlags(SqliteLocalStorage s, String table) async => [
        for (final r in await dbOf(s).query(table, columns: ['sync_dirty']))
          r['sync_dirty'] as int,
      ];

  Future<void> expectAllClean(SqliteLocalStorage s) async {
    for (final t in ['songs', 'folders', 'folder_songs', 'sync_tombstones']) {
      expect(await dirtyFlags(s, t), everyElement(0), reason: t);
    }
  }

  /// Two devices bound to the same account and holding the same data:
  /// A uploads first (initial sync), B restores.
  Future<(SqliteLocalStorage, SqliteLocalStorage, FakeCloudBackend, Song, Folder)>
      twoDevices() async {
    final cloud = FakeCloudBackend();
    final a = await device();
    final song = await addSong(a, '공통 곡', number: '1');
    final folder = await addFolder(a, '공통 폴더');
    await a.folders.addSong(folder.id!, song.id!);
    await InitialSyncEngine(store: a.syncStore, backend: cloud)
        .run(_uid, mode: InitialSyncMode.upload);
    final b = await device();
    await InitialSyncEngine(store: b.syncStore, backend: cloud)
        .run(_uid, mode: InitialSyncMode.restore);
    return (a, b, cloud, song, folder);
  }

  // -------------------------------------------------------------------------
  group('pull and upload', () {
    test('a new local song is uploaded, then pulled by the other device',
        () async {
      final (a, b, cloud, _, _) = await twoDevices();
      final added = await addSong(a, '새 곡', number: '200');
      expect((await songRow(a, added.syncId!))!['sync_dirty'], 1);

      final r = await manual(a, cloud).syncNow(_uid);
      expect(r.uploadedDocuments, 1);
      expect(cloud.docOf(_uid, 'songs', added.syncId!)!['title'], '새 곡');
      expect((await songRow(a, added.syncId!))!['sync_dirty'], 0);

      final rb = await manual(b, cloud).syncNow(_uid);
      expect(rb.localChanges, greaterThan(0));
      final onB = await songBySyncId(b, added.syncId!);
      expect(onB!.title, '새 곡');
      await expectAllClean(b);
    });

    test('folders: a new folder is pulled; a rename is uploaded', () async {
      final (a, b, cloud, _, common) = await twoDevices();
      final f = await addFolder(a, '새 폴더');
      await sync(a, cloud);
      await sync(b, cloud);
      expect((await folderBySyncId(b, f.syncId!))!.name, '새 폴더');

      final onB = (await folderBySyncId(b, common.syncId!))!;
      await b.folders.update(onB.copyWith(name: '이름 바꿈'));
      await sync(b, cloud);
      expect(cloud.docOf(_uid, 'folders', common.syncId!)!['name'], '이름 바꿈');
      await sync(a, cloud);
      expect((await folderBySyncId(a, common.syncId!))!.name, '이름 바꿈');
      await expectAllClean(a);
      await expectAllClean(b);
    });

    test('folder memberships are uploaded and pulled', () async {
      final (a, b, cloud, _, folder) = await twoDevices();
      final s2 = await addSong(a, '두 번째', number: '2');
      await a.folders.addSong(folder.id!, s2.id!);
      await sync(a, cloud);
      expect(
        cloud.docOf(_uid, 'folderSongs', '${folder.syncId}_${s2.syncId}')!['deleted'],
        isFalse,
      );
      await sync(b, cloud);
      expect(await memberSyncIds(b, folder.syncId!), contains(s2.syncId));

      // Removal travels too.
      final folderOnB = (await folderBySyncId(b, folder.syncId!))!;
      final s2OnB = (await songBySyncId(b, s2.syncId!))!;
      await b.folders.removeSong(folderOnB.id!, s2OnB.id!);
      await sync(b, cloud);
      await sync(a, cloud);
      expect(await memberSyncIds(a, folder.syncId!), isNot(contains(s2.syncId)));
      await expectAllClean(a);
    });

    test('pull first, then the remaining local changes are uploaded',
        () async {
      final (a, b, cloud, song, _) = await twoDevices();
      final fromB = await addSong(b, 'B의 새 곡', number: '300');
      await sync(b, cloud);
      await editSong(a, song.syncId!, 'A가 수정', atMs: 9000000000000);

      final r = await manual(a, cloud).syncNow(_uid);
      expect(r.localChanges, greaterThan(0));
      expect(await songBySyncId(a, fromB.syncId!), isNotNull);
      expect(cloud.docOf(_uid, 'songs', song.syncId!)!['title'], 'A가 수정');
      await expectAllClean(a);
    });

    test('new songs from different devices are both kept', () async {
      final (a, b, cloud, _, _) = await twoDevices();
      final x = await addSong(a, '같은 제목', number: '777');
      final y = await addSong(b, '같은 제목', number: '777');
      await sync(a, cloud);
      await sync(b, cloud);
      await sync(a, cloud);
      for (final d in [a, b]) {
        expect(await songBySyncId(d, x.syncId!), isNotNull);
        expect(await songBySyncId(d, y.syncId!), isNotNull);
        expect((await d.songs.getAll()).length, 3);
      }
    });
  });

  // -------------------------------------------------------------------------
  group('conflicts', () {
    test('cloud newer wins', () async {
      final (a, b, cloud, song, _) = await twoDevices();
      await editSong(b, song.syncId!, 'B 최신', atMs: 2000000000000);
      await sync(b, cloud);
      await editSong(a, song.syncId!, 'A 옛날', atMs: 1000000000000);
      await sync(a, cloud);
      expect((await songBySyncId(a, song.syncId!))!.title, 'B 최신');
      expect((await songRow(a, song.syncId!))!['sync_dirty'], 0);
      expect(cloud.docOf(_uid, 'songs', song.syncId!)!['title'], 'B 최신');
    });

    test('local newer wins and is uploaded', () async {
      final (a, b, cloud, song, _) = await twoDevices();
      await editSong(b, song.syncId!, 'B 옛날', atMs: 1000000000000);
      await sync(b, cloud);
      await editSong(a, song.syncId!, 'A 최신', atMs: 2000000000000);
      await sync(a, cloud);
      expect((await songBySyncId(a, song.syncId!))!.title, 'A 최신');
      expect(cloud.docOf(_uid, 'songs', song.syncId!)!['title'], 'A 최신');
      await expectAllClean(a);
      await sync(b, cloud);
      expect((await songBySyncId(b, song.syncId!))!.title, 'A 최신');
    });

    test('same time: the cloud wins', () async {
      final (a, b, cloud, song, _) = await twoDevices();
      await editSong(b, song.syncId!, 'B 판', atMs: 5000000000000);
      await sync(b, cloud);
      await editSong(a, song.syncId!, 'A 판', atMs: 5000000000000);
      await sync(a, cloud);
      expect((await songBySyncId(a, song.syncId!))!.title, 'B 판');
      expect(cloud.docOf(_uid, 'songs', song.syncId!)!['title'], 'B 판');
    });

    test('a cloud deletion removes the song, its memberships, cleanly',
        () async {
      final (a, b, cloud, song, folder) = await twoDevices();
      await a.songs.delete(song.id!);
      await sync(a, cloud);
      expect(cloud.docOf(_uid, 'songs', song.syncId!)!['deleted'], isTrue);
      await expectAllClean(a);

      await sync(b, cloud);
      expect(await songBySyncId(b, song.syncId!), isNull);
      expect(await memberSyncIds(b, folder.syncId!), isEmpty);
      final tomb = await dbOf(b).query('sync_tombstones',
          where: 'sync_id = ?', whereArgs: [song.syncId]);
      expect(tomb.single['sync_dirty'], 0);
      await expectAllClean(b);
    });

    test('deletion beats a later edit (cloud deleted, local edited)',
        () async {
      final (a, b, cloud, song, _) = await twoDevices();
      await a.songs.delete(song.id!);
      await sync(a, cloud);
      await editSong(b, song.syncId!, 'B가 늦게 수정', atMs: 9000000000000);
      await sync(b, cloud); // the fake rejects any revive: success = none
      expect(await songBySyncId(b, song.syncId!), isNull);
      expect(cloud.docOf(_uid, 'songs', song.syncId!)!['deleted'], isTrue);
      await expectAllClean(b);
    });

    test('deletion beats a later edit (local deleted, cloud edited)',
        () async {
      final (a, b, cloud, song, _) = await twoDevices();
      await editSong(b, song.syncId!, 'B 수정', atMs: 9000000000000);
      await sync(b, cloud);
      await a.songs.delete(song.id!); // before pulling B's newer edit
      await sync(a, cloud);
      expect(await songBySyncId(a, song.syncId!), isNull);
      expect(cloud.docOf(_uid, 'songs', song.syncId!)!['deleted'], isTrue);
      await sync(b, cloud);
      expect(await songBySyncId(b, song.syncId!), isNull);
    });

    test('a deleted folder takes its memberships, never the songs', () async {
      final (a, b, cloud, song, folder) = await twoDevices();
      await a.folders.delete(folder.id!);
      await sync(a, cloud);
      await sync(b, cloud);
      expect(await folderBySyncId(b, folder.syncId!), isNull);
      expect(await songBySyncId(b, song.syncId!), isNotNull);
      expect(await dbOf(b).query('folder_songs'), isEmpty);
    });

    test('re-adding a song to a folder after a synced removal: the re-add '
        '(a higher revision) wins everywhere', () async {
      final (a, b, cloud, song, folder) = await twoDevices();
      cloud.clockStepMs = 100000;
      await a.folders.removeSong(folder.id!, song.id!);
      await sync(a, cloud);
      // Later membership changes push the cursor far past the deletion, so
      // the deleted document is no longer in the pull window.
      for (var i = 0; i < 2; i++) {
        final other = await addSong(a, '다른 곡 $i', number: '9$i');
        await a.folders.addSong(folder.id!, other.id!);
        await sync(a, cloud);
      }
      final lookupsBefore = cloud.fetchByIdsCount;
      await a.folders.addSong(folder.id!, song.id!); // explicit re-add
      await sync(a, cloud); // allowed by the rules: revision 3 > 2
      expect(cloud.fetchByIdsCount, lookupsBefore + 1);
      expect(await memberSyncIds(a, folder.syncId!), contains(song.syncId));
      final doc = cloud.docOf(
          _uid, 'folderSongs', '${folder.syncId}_${song.syncId}')!;
      expect(doc['deleted'], isFalse);
      expect(doc['revision'], 3);
      await expectAllClean(a);

      await sync(b, cloud);
      expect(await memberSyncIds(b, folder.syncId!), contains(song.syncId));
    });
  });

  // -------------------------------------------------------------------------
  group('dirty, cursors and failures', () {
    test('a row edited during the upload stays dirty', () async {
      final (a, _, cloud, song, _) = await twoDevices();
      await editSong(a, song.syncId!, '업로드 직전', atMs: 9000000000000);
      final base = cloud.commitCount;
      cloud.beforeCommit = (n) async {
        if (n != base + 1) return;
        await editSong(a, song.syncId!, '업로드 중 수정', atMs: 9000000000001);
      };
      final before = cloud.commitCount;
      await sync(a, cloud);
      expect(cloud.commitCount, before + 1);
      expect(cloud.docOf(_uid, 'songs', song.syncId!)!['title'], '업로드 직전');
      expect((await songRow(a, song.syncId!))!['sync_dirty'], 1);
      expect((await songBySyncId(a, song.syncId!))!.title, '업로드 중 수정');

      cloud.beforeCommit = null;
      await sync(a, cloud);
      expect(cloud.docOf(_uid, 'songs', song.syncId!)!['title'], '업로드 중 수정');
      await expectAllClean(a);
    });

    test('cursors: set after success, pulled with a 60 s overlap', () async {
      final (a, _, cloud, _, _) = await twoDevices();
      cloud.clockStepMs = 100000;
      await addSong(a, '커서 확인');
      await sync(a, cloud);
      final cursors = await a.syncStore.readPullCursors();
      expect(cursors.songsMs, isNotNull);
      expect(cursors.foldersMs, isNotNull);
      expect(cursors.folderSongsMs, isNotNull);
      await sync(a, cloud);
      expect(cloud.lastSince[0],
          cursors.songsMs! - ManualSyncEngine.overlapMs);
    });

    test('partial failure: finished batches are clean, the rest stays '
        'dirty, cursors do not move; a retry completes', () async {
      final (a, _, cloud, _, _) = await twoDevices();
      await sync(a, cloud);
      final cursorsBefore = await a.syncStore.readPullCursors();
      final lastBefore = await readSyncMeta(
          dbOf(a), SyncMetaKeys.lastSuccessfulSyncAtMs);
      for (var i = 0; i < 5; i++) {
        await addSong(a, '추가 $i', number: '5$i');
      }
      cloud.failOnCommit = cloud.commitCount + 2;
      await expectLater(
        manual(a, cloud, batchSize: 2).syncNow(_uid),
        throwsA(isA<ManualSyncFailure>()
            .having((f) => f.kind, 'kind', ManualSyncFailureKind.network)),
      );
      final flags = await dirtyFlags(a, 'songs');
      expect(flags.where((f) => f == 0).length, 1 + 2); // common + batch 1
      expect(flags.where((f) => f == 1).length, 3);
      final cursorsAfter = await a.syncStore.readPullCursors();
      expect(cursorsAfter.songsMs, cursorsBefore.songsMs);
      expect(await readSyncMeta(dbOf(a), SyncMetaKeys.lastSuccessfulSyncAtMs),
          lastBefore);
      expect(await readSyncMeta(dbOf(a), SyncMetaKeys.accountUid), _uid);

      cloud.failOnCommit = null;
      await manual(a, cloud, batchSize: 2).syncNow(_uid);
      await expectAllClean(a);
      expect(cloud.docCount(_uid, 'songs'), 6);
    });

    test('network failure: nothing lost, app still usable, retry works',
        () async {
      final (a, _, cloud, song, _) = await twoDevices();
      await editSong(a, song.syncId!, '오프라인 수정', atMs: 9000000000000);
      cloud.fetchError = const CloudSyncBackendException(
          CloudSyncErrorKind.network, 'offline');
      await expectLater(
        sync(a, cloud),
        throwsA(isA<ManualSyncFailure>()
            .having((f) => f.kind, 'kind', ManualSyncFailureKind.network)),
      );
      expect((await songRow(a, song.syncId!))!['sync_dirty'], 1);
      expect(await readSyncMeta(dbOf(a), SyncMetaKeys.accountUid), _uid);
      expect(await readSyncMeta(dbOf(a), SyncMetaKeys.syncApplyInProgress),
          isNull);
      await addSong(a, '오프라인 추가'); // local use continues
      expect((await a.songs.getAll()).length, 2);

      cloud.fetchError = null;
      await sync(a, cloud);
      expect(cloud.docOf(_uid, 'songs', song.syncId!)!['title'], '오프라인 수정');
      await expectAllClean(a);
    });

    test('a failing dirty-row lookup also leaves everything as it was',
        () async {
      final (a, b, cloud, song, _) = await twoDevices();
      cloud.clockStepMs = 100000;
      // Move A's song cursor well past the common song's server time, so
      // the edited song is not in the overlap window and must be looked up.
      await addSong(b, '나중 곡');
      await sync(b, cloud);
      await sync(a, cloud);
      await editSong(a, song.syncId!, '수정', atMs: 9000000000000);
      cloud.fetchByIdsError = const CloudSyncBackendException(
          CloudSyncErrorKind.network, 'offline');
      await expectLater(sync(a, cloud), throwsA(isA<ManualSyncFailure>()));
      expect((await songRow(a, song.syncId!))!['sync_dirty'], 1);
      expect(cloud.docOf(_uid, 'songs', song.syncId!)!['title'], '공통 곡');
    });

    test('running the same sync twice changes nothing the second time',
        () async {
      final (a, b, cloud, _, _) = await twoDevices();
      await addSong(b, 'B 곡');
      await sync(b, cloud);
      await sync(a, cloud);
      final commits = cloud.commitCount;
      final tables = await dumpUserTables(dbOf(a));
      final r = await manual(a, cloud).syncNow(_uid);
      expect(r.localChanges, 0);
      expect(r.uploadedDocuments, 0);
      expect(cloud.commitCount, commits);
      expect(await dumpUserTables(dbOf(a)), tables);
    });

    test('a device not bound to this account does not sync at all',
        () async {
      final cloud = FakeCloudBackend();
      final s = await device();
      await addSong(s, '곡');
      final before = await dumpUserTables(dbOf(s));
      await expectLater(
        sync(s, cloud),
        throwsA(isA<ManualSyncFailure>().having(
            (f) => f.kind, 'kind', ManualSyncFailureKind.accountMismatch)),
      );
      await writeSyncMeta(dbOf(s), SyncMetaKeys.accountUid, 'uid-bob');
      await expectLater(sync(s, cloud), throwsA(isA<ManualSyncFailure>()));
      expect(cloud.fetchCount, 0);
      expect(cloud.commitCount, 0);
      expect(await dumpUserTables(dbOf(s)), before);
      expect(await readSyncMeta(dbOf(s), SyncMetaKeys.accountUid), 'uid-bob');
    });
  });

  // -------------------------------------------------------------------------
  group('controller and UI', () {
    Future<(AccountController, CloudSyncController)> connected(
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
        engine: InitialSyncEngine(store: s.syncStore, backend: cloud),
        manual: ManualSyncEngine(store: s.syncStore, backend: cloud),
        account: account,
      );
      account.cloudSync = sync;
      return (account, sync);
    }

    test('sync now: success, duplicate taps ignored, data change reported',
        () async {
      final (a, b, cloud, _, _) = await twoDevices();
      await addSong(b, 'B 곡');
      await sync(b, cloud);
      final (_, controller) = await connected(a, cloud);
      expect(controller.phase, CloudSyncPhase.connected);
      final version = controller.dataVersion;

      cloud.fetchGate = Completer<void>();
      final first = controller.syncNow();
      final second = controller.syncNow();
      expect(controller.manualStatus, ManualSyncStatus.running);
      expect(controller.busy, isTrue);
      cloud.fetchGate!.complete();
      await Future.wait([first, second]);
      expect(cloud.fetchChangedCount, 2); // b's sync + one for a's two taps
      expect(controller.manualStatus, ManualSyncStatus.succeeded);
      expect(controller.dataVersion, version + 1);
      expect(controller.lastSyncAtMs, isNotNull);
      controller.dispose();
    });

    test('sync now failure: message, data and binding kept, retry works',
        () async {
      final (a, _, cloud, _, _) = await twoDevices();
      final (account, controller) = await connected(a, cloud);
      cloud.fetchError = const CloudSyncBackendException(
          CloudSyncErrorKind.network, 'offline');
      await controller.syncNow();
      expect(controller.manualStatus, ManualSyncStatus.failed);
      expect(controller.manualMessage, '동기화하지 못했어요. 이 기기의 데이터는 그대로예요.');
      expect(controller.phase, CloudSyncPhase.connected);
      expect(account.linkStatus, AccountLinkStatus.sameAccount);
      cloud.fetchError = null;
      await controller.syncNow();
      expect(controller.manualStatus, ManualSyncStatus.succeeded);
      controller.dispose();
    });

    testWidgets('sheet: last sync time, "지금 동기화", "동기화 완료"',
        (tester) async {
      late SqliteLocalStorage a;
      late FakeCloudBackend cloud;
      late AccountController account;
      late CloudSyncController controller;
      await tester.runAsync(() async {
        final setup = await twoDevices();
        a = setup.$1;
        cloud = setup.$3;
        (account, controller) = await connected(a, cloud);
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: AccountSheet(account: account)),
      ));
      await tester.pump();
      expect(find.text('백업 연결됨'), findsOneWidget);
      expect(find.textContaining('마지막 동기화:'), findsOneWidget);
      expect(find.text('지금 동기화'), findsOneWidget);

      await tester.runAsync(controller.syncNow);
      await tester.pump();
      expect(find.byKey(const Key('cloudSyncDone')), findsOneWidget);
      expect(find.text('동기화 완료'), findsOneWidget);

      cloud.fetchError = const CloudSyncBackendException(
          CloudSyncErrorKind.network, 'offline');
      await tester.runAsync(controller.syncNow);
      await tester.pump();
      expect(find.text('동기화하지 못했어요. 이 기기의 데이터는 그대로예요.'),
          findsOneWidget);
      expect(find.text('다시 시도'), findsOneWidget);
      controller.dispose();
    });

    testWidgets('a sync that changed local data refreshes the screens',
        (tester) async {
      final storage = InMemoryLocalStorage();
      await storage.init();
      final account = AccountController(
        gateway: FakeAuth(_alice),
        boundAccount: _NoBinding(),
      );
      final controller = CloudSyncController(
        engine: InitialSyncEngine(store: _UnusedStore(), backend: FakeCloudBackend()),
        account: account,
      );
      account.cloudSync = controller;
      await tester.pumpWidget(UtaNoteApp(storage: storage, account: account));
      await tester.pumpAndSettle();
      expect(find.text('노래가 없습니다.'), findsOneWidget);

      // Written behind the screen's back, like a pull would.
      await storage.songs.create(Song(
        karaokeType: 'TJ',
        songNumber: '42',
        title: '동기화로 온 곡',
        createdAt: day,
        updatedAt: day,
      ));
      expect(find.text('동기화로 온 곡'), findsNothing);
      controller.debugMarkDataChanged();
      await tester.pumpAndSettle();
      expect(find.text('동기화로 온 곡'), findsOneWidget);
      controller.dispose();
    });
  });
}

class _Bound implements BoundAccountSource {
  final SqliteLocalStorage storage;
  _Bound(this.storage);

  @override
  Future<String?> readBoundAccountUid() => storage.readBoundAccountUid();
}

class _NoBinding implements BoundAccountSource {
  @override
  Future<String?> readBoundAccountUid() async => null;
}

/// Never called in the screen-refresh test.
class _UnusedStore implements LocalSyncStore {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}
