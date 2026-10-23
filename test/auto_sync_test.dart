import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
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
import 'package:utanote/storage/observed_local_storage.dart';
import 'package:utanote/sync/cloud_sync_backend.dart';
import 'package:utanote/sync/cloud_sync_controller.dart';
import 'package:utanote/sync/initial_sync_engine.dart';
import 'package:utanote/sync/local_sync_store.dart';
import 'package:utanote/sync/manual_sync.dart';

import 'support/sync_fakes.dart';

/// Phase B-4B: automatic sync — at start (restored session on a bound
/// device), on return to the foreground (throttled) and after user edits
/// (debounced); one run at a time with a single follow-up; quiet failure
/// with backoff. Real SQLite + the fake cloud.

const _uid = 'uid-alice';
const _alice = AccountUser(uid: _uid, email: 'alice@example.com');
const _debounce = Duration(milliseconds: 80);

void main() {
  late Directory root;
  var counter = 0;
  final opened = <SqliteLocalStorage>[];
  final controllers = <CloudSyncController>[];

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    root = await Directory.systemTemp.createTemp('utanote_auto_sync_');
  });

  tearDown(() async {
    for (final c in controllers) {
      c.dispose();
    }
    controllers.clear();
    for (final s in opened) {
      await s.close();
    }
    opened.clear();
  });

  Future<SqliteLocalStorage> device() async {
    final dir = p.join(root.path, 'd${counter++}');
    await Directory(dir).create(recursive: true);
    await databaseFactory.setDatabasesPath(dir);
    final s = SqliteLocalStorage();
    await s.init();
    opened.add(s);
    return s;
  }

  final day = DateTime.parse('2024-01-01T00:00:00.000');
  Song song(String title) => Song(
      karaokeType: 'TJ',
      songNumber: '1',
      title: title,
      createdAt: day,
      updatedAt: day);

  /// A device whose data is already connected to [_uid].
  Future<(SqliteLocalStorage, FakeCloudBackend)> boundDevice() async {
    final cloud = FakeCloudBackend();
    final s = await device();
    await s.songs.create(song('기존 곡'));
    await InitialSyncEngine(store: s.syncStore, backend: cloud)
        .run(_uid, mode: InitialSyncMode.upload);
    return (s, cloud);
  }

  var clockMs = 1000000000;

  /// App start: the controller exists before the session is restored,
  /// exactly like production (Firebase restores it asynchronously).
  Future<(CloudSyncController, ObservedLocalStorage, FakeAuth)> start(
    SqliteLocalStorage s,
    FakeCloudBackend cloud, {
    Duration backoffBase = const Duration(minutes: 1),
    bool realClock = false,
  }) async {
    final auth = FakeAuth(_alice);
    final account = AccountController(gateway: auth, boundAccount: _Bound(s));
    final controller = CloudSyncController(
      engine: InitialSyncEngine(store: s.syncStore, backend: cloud),
      manual: ManualSyncEngine(store: s.syncStore, backend: cloud),
      account: account,
      autoSync: AutoSyncConfig(
        debounce: _debounce,
        backoffBase: backoffBase,
        now: realClock
            ? () => DateTime.now().toUtc().millisecondsSinceEpoch
            : () => clockMs,
      ),
    );
    controllers.add(controller);
    account.cloudSync = controller;
    final ui = ObservedLocalStorage(
      s,
      onUserDataChanged: controller.onLocalDataChanged,
    );
    await account.start();
    auth.users.add(_alice); // Firebase restores the saved session
    // Let the restored session be fully applied (binding read included)
    // before the test starts editing.
    for (var i = 0; i < 50 && account.phase != AccountPhase.signedIn; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    await Future<void>.delayed(const Duration(milliseconds: 30));
    return (controller, ui, auth);
  }

  /// Lets timers, debounces, runs and follow-ups finish.
  Future<void> idle(CloudSyncController c, {Duration extra = Duration.zero}) async {
    await Future<void>.delayed(_debounce * 2 + extra);
    while (c.busy) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
    while (c.busy) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  Future<int> dirtySongs(SqliteLocalStorage s) async => (await s
          .databaseForTesting
          .query('songs', where: 'sync_dirty = 1'))
      .length;

  // -------------------------------------------------------------------------
  group('app start', () {
    test('bound device with a restored session syncs once', () async {
      final (s, cloud) = await boundDevice();
      final (c, _, _) = await start(s, cloud);
      await idle(c);
      expect(c.phase, CloudSyncPhase.connected);
      expect(c.syncRuns, 1);
      expect(cloud.fetchChangedCount, 1);
      expect(c.manualStatus, ManualSyncStatus.idle); // quiet success
      expect(c.lastSyncAtMs, isNotNull);
    });

    test('unbound device: no automatic sync, not even after edits', () async {
      final cloud = FakeCloudBackend();
      final s = await device();
      await s.songs.create(song('곡'));
      final (c, ui, _) = await start(s, cloud);
      await ui.songs.create(song('또 하나'));
      await idle(c);
      expect(c.phase, CloudSyncPhase.notConnected);
      expect(c.syncRuns, 0);
      expect(cloud.fetchCount, 0);
      expect(cloud.commitCount, 0);
      expect(await readSyncMeta(s.databaseForTesting, SyncMetaKeys.accountUid),
          isNull);
    });

    test('bound to another account: no automatic sync', () async {
      final (s, cloud) = await boundDevice();
      await writeSyncMeta(
          s.databaseForTesting, SyncMetaKeys.accountUid, 'uid-bob');
      final before = cloud.fetchChangedCount;
      final (c, ui, auth) = await start(s, cloud);
      await ui.songs.create(song('곡'));
      c.onAppResumed();
      await idle(c);
      expect(c.phase, isNot(CloudSyncPhase.connected));
      expect(c.syncRuns, 0);
      expect(cloud.fetchChangedCount, before);
    });
  });

  // -------------------------------------------------------------------------
  group('foreground', () {
    test('resume syncs; repeated resumes within a minute run once', () async {
      final (s, cloud) = await boundDevice();
      final (c, _, _) = await start(s, cloud);
      await idle(c);
      expect(c.syncRuns, 1); // start

      c.onAppResumed(); // within the minute after the start sync
      await idle(c);
      expect(c.syncRuns, 1);

      clockMs += const Duration(seconds: 61).inMilliseconds;
      c.onAppResumed();
      c.onAppResumed();
      c.onAppResumed();
      await idle(c);
      expect(c.syncRuns, 2);
    });
  });

  testWidgets('the app returning to the foreground reaches the controller',
      (tester) async {
    final storage = InMemoryLocalStorage();
    await storage.init();
    final account = AccountController(
        gateway: FakeAuth(_alice), boundAccount: _NoBound());
    final spy = _ResumeSpy(account);
    account.cloudSync = spy;
    await tester.pumpWidget(UtaNoteApp(storage: storage, account: account));
    await tester.pumpAndSettle();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    expect(spy.resumes, 0);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    expect(spy.resumes, 1);
    spy.dispose();
  });

  // -------------------------------------------------------------------------
  group('data changes', () {
    test('adding a song syncs after the debounce and uploads it', () async {
      final (s, cloud) = await boundDevice();
      final (c, ui, _) = await start(s, cloud);
      await idle(c);
      final created = await ui.songs.create(song('새 곡'));
      expect(c.syncRuns, 1); // not yet: debounce
      await idle(c);
      expect(c.syncRuns, 2);
      expect(cloud.docOf(_uid, 'songs', created.syncId!)!['title'], '새 곡');
      expect(await dirtySongs(s), 0);
    });

    test('many quick edits: one sync after the debounce', () async {
      final (s, cloud) = await boundDevice();
      final (c, ui, _) = await start(s, cloud);
      await idle(c);
      var x = await ui.songs.create(song('편집'));
      for (var i = 0; i < 5; i++) {
        x = x.copyWith(title: '편집 $i');
        await ui.songs.update(x);
      }
      await idle(c);
      expect(c.syncRuns, 2);
      expect(cloud.docOf(_uid, 'songs', x.syncId!)!['title'], '편집 4');
    });

    test('folder create / rename / add / remove / delete and song delete '
        'all trigger', () async {
      final (s, cloud) = await boundDevice();
      final (c, ui, _) = await start(s, cloud);
      await idle(c);
      var runs = c.syncRuns;
      Future<void> expectSynced(Future<void> Function() action) async {
        await action();
        await idle(c);
        expect(c.syncRuns, ++runs);
      }

      late Folder f;
      await expectSynced(() async => f = await ui.folders
          .create(Folder(name: '폴더', createdAt: day, updatedAt: day)));
      await expectSynced(() => ui.folders.update(f.copyWith(name: '새 이름')));
      final x = (await ui.songs.getAll()).first;
      await expectSynced(() => ui.folders.addSong(f.id!, x.id!));
      await expectSynced(() => ui.folders.removeSong(f.id!, x.id!));
      await expectSynced(() => ui.folders.delete(f.id!));
      await expectSynced(() => ui.songs.delete(x.id!));
      expect(cloud.docOf(_uid, 'folders', f.syncId!)!['deleted'], isTrue);
      expect(cloud.docOf(_uid, 'songs', x.syncId!)!['deleted'], isTrue);
    });

    test('browsing, searching and reading never trigger', () async {
      final (s, cloud) = await boundDevice();
      final (c, ui, _) = await start(s, cloud);
      await idle(c);
      await ui.songs.getAll();
      await ui.songs.search('곡');
      await ui.songs.getById(1);
      await ui.folders.getAll();
      await ui.folders.getSongIds(1);
      await idle(c);
      expect(c.syncRuns, 1);
    });

    test('a change during a running sync gets one more sync afterwards',
        () async {
      final (s, cloud) = await boundDevice();
      final (c, ui, _) = await start(s, cloud);
      await idle(c);
      cloud.fetchGate = Completer<void>();
      clockMs += const Duration(minutes: 2).inMilliseconds;
      c.onAppResumed(); // run #2 starts and waits on the gate
      expect(c.busy, isTrue);
      final a = await ui.songs.create(song('실행 중 추가 1'));
      final b = await ui.songs.create(song('실행 중 추가 2'));
      c.onAppResumed();
      await c.syncNow(); // also folded into the same single follow-up
      await Future<void>.delayed(_debounce * 2);
      expect(c.syncRuns, 2); // never concurrent
      cloud.fetchGate!.complete();
      cloud.fetchGate = null;
      await idle(c);
      expect(c.syncRuns, 3); // exactly one follow-up
      expect(cloud.docOf(_uid, 'songs', a.syncId!), isNotNull);
      expect(cloud.docOf(_uid, 'songs', b.syncId!), isNotNull);
      expect(await dirtySongs(s), 0);
    });
  });

  // -------------------------------------------------------------------------
  group('failures', () {
    test('network failure: quiet, data stays dirty, no immediate retry; '
        'retried after the backoff', () async {
      final (s, cloud) = await boundDevice();
      cloud.fetchError = const CloudSyncBackendException(
          CloudSyncErrorKind.network, 'offline');
      final (c, ui, _) = await start(s, cloud,
          backoffBase: const Duration(milliseconds: 1500), realClock: true);
      await idle(c);
      expect(c.syncRuns, 1);
      expect(c.manualStatus, ManualSyncStatus.failed);
      expect(c.manualMessage, '동기화하지 못했어요. 이 기기의 데이터는 그대로예요.');

      final x = await ui.songs.create(song('오프라인 곡'));
      c.onAppResumed();
      await idle(c);
      expect(c.syncRuns, 1); // backoff: nothing retried yet
      expect(await dirtySongs(s), greaterThan(0));
      expect(await readSyncMeta(s.databaseForTesting, SyncMetaKeys.accountUid),
          _uid);

      cloud.fetchError = null;
      await idle(c, extra: const Duration(milliseconds: 1600));
      expect(c.syncRuns, 2); // the pending edit, once the backoff ended
      expect(cloud.docOf(_uid, 'songs', x.syncId!)!['title'], '오프라인 곡');
      expect(await dirtySongs(s), 0);
      expect(c.manualStatus, ManualSyncStatus.idle);
    });

    test('backoff grows with consecutive failures', () async {
      final (s, cloud) = await boundDevice();
      cloud.fetchError = const CloudSyncBackendException(
          CloudSyncErrorKind.network, 'offline');
      final (c, _, _) = await start(s, cloud);
      await idle(c);
      expect(c.syncRuns, 1);
      clockMs += const Duration(seconds: 61).inMilliseconds; // > 1 min
      c.onAppResumed();
      await idle(c);
      expect(c.syncRuns, 2);
      clockMs += const Duration(seconds: 90).inMilliseconds; // < 2 min
      c.onAppResumed();
      await idle(c);
      expect(c.syncRuns, 2);
      clockMs += const Duration(seconds: 40).inMilliseconds; // > 2 min
      c.onAppResumed();
      await idle(c);
      expect(c.syncRuns, 3);
    });
  });

  // -------------------------------------------------------------------------
  group('manual', () {
    test('"지금 동기화" ignores the throttle and the backoff', () async {
      final (s, cloud) = await boundDevice();
      cloud.fetchError = const CloudSyncBackendException(
          CloudSyncErrorKind.network, 'offline');
      final (c, _, _) = await start(s, cloud);
      await idle(c);
      expect(c.syncRuns, 1); // failed; backoff + throttle now active
      cloud.fetchError = null;
      await c.syncNow();
      await idle(c);
      expect(c.syncRuns, 2);
      expect(c.manualStatus, ManualSyncStatus.succeeded);
      await c.syncNow(); // right again, still allowed
      await idle(c);
      expect(c.syncRuns, 3);
    });

    test('automatic and manual never run at the same time', () async {
      final (s, cloud) = await boundDevice();
      cloud.fetchGate = Completer<void>();
      final (c, _, _) = await start(s, cloud);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(c.busy, isTrue); // the start sync, held on the gate
      final tap = c.syncNow();
      await tap;
      expect(c.syncRuns, 1);
      cloud.fetchGate!.complete();
      cloud.fetchGate = null;
      await idle(c);
      expect(c.syncRuns, 2); // the tap ran afterwards, once
    });
  });
}

class _ResumeSpy extends CloudSyncController {
  int resumes = 0;

  _ResumeSpy(AccountController account)
      : super(
          engine: InitialSyncEngine(
              store: _UnusedStore(), backend: FakeCloudBackend()),
          account: account,
        );

  @override
  void onAppResumed() => resumes++;
}

class _UnusedStore implements LocalSyncStore {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _NoBound implements BoundAccountSource {
  @override
  Future<String?> readBoundAccountUid() async => null;
}

class _Bound implements BoundAccountSource {
  final SqliteLocalStorage storage;
  _Bound(this.storage);

  @override
  Future<String?> readBoundAccountUid() => storage.readBoundAccountUid();
}
