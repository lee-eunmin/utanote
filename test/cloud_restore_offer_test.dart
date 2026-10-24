import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:utanote/account/account_controller.dart';
import 'package:utanote/sync/account_data_deletion.dart';
import 'package:utanote/account/auth_gateway.dart';
import 'package:utanote/models/song.dart';
import 'package:utanote/storage/android/sqlite_local_storage.dart';
import 'package:utanote/storage/android/sqlite_pre_cloud_backup.dart';
import 'package:utanote/storage/android/sqlite_pre_migration_backup.dart';
import 'package:utanote/storage/android/sqlite_schema.dart';
import 'package:utanote/storage/memory/in_memory_local_storage.dart';
import 'package:utanote/sync/cloud_sync_backend.dart';
import 'package:utanote/sync/cloud_sync_controller.dart';
import 'package:utanote/sync/initial_sync_engine.dart';
import 'package:utanote/sync/manual_sync.dart';
import 'package:utanote/ui/app_shell.dart';

import 'support/sync_fakes.dart';

/// Empty-songbook restore offer: after sign-in, a song-less unbound device
/// looks (read-only) for a cloud backup and offers restoring it through the
/// normal first connection. Real SQLite (sqflite_common_ffi) + fake cloud.

const _uid = 'uid-alice';
const _alice = AccountUser(uid: _uid, email: 'alice@example.com');

String _songId(int i) =>
    '50000000-0000-4000-8000-${i.toString().padLeft(12, '0')}';
String _folderId(int i) =>
    'f0000000-0000-4000-8000-${i.toString().padLeft(12, '0')}';

/// Cloud with [songs] live songs and [folders] live folders.
FakeCloudBackend _cloudWith({int songs = 10, int folders = 3}) {
  final cloud = FakeCloudBackend();
  for (var i = 1; i <= songs; i++) {
    cloud.seed(
      _uid,
      CloudDocCodec.putSong(_songId(i), songData('곡 $i'), 1000 + i),
    );
  }
  for (var i = 1; i <= folders; i++) {
    cloud.seed(
      _uid,
      CloudDocCodec.putFolder(_folderId(i), folderData('폴더 $i'), 2000 + i),
    );
  }
  return cloud;
}

class _Bound implements BoundAccountSource {
  final SqliteLocalStorage storage;
  _Bound(this.storage);

  @override
  Future<String?> readBoundAccountUid() => storage.readBoundAccountUid();
}

class _FailingAuth extends FakeAuth {
  _FailingAuth() : super(_alice);

  @override
  Future<AccountUser> signInWithGoogle() async =>
      throw const AccountSignInFailure('로그인하지 못했어요.');
}

class _NoBinding implements BoundAccountSource {
  @override
  Future<String?> readBoundAccountUid() async => null;
}

void main() {
  late String dbDir;
  late String dbPath;
  late String cloudBackupPath;
  final opened = <SqliteLocalStorage>[];

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final tempDir = await Directory.systemTemp.createTemp(
      'utanote_restore_offer_test_',
    );
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
    for (final path in [
      cloudBackupPath,
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

  Database dbOf(SqliteLocalStorage s) => s.databaseForTesting;

  Future<String?> boundUid(SqliteLocalStorage s) =>
      readSyncMeta(dbOf(s), SyncMetaKeys.accountUid);

  Future<Song> addSong(SqliteLocalStorage s, String title) {
    final day = DateTime.parse('2024-01-01T00:00:00.000');
    return s.songs.create(
      Song(
        karaokeType: 'TJ',
        songNumber: '1',
        title: title,
        createdAt: day,
        updatedAt: day,
      ),
    );
  }

  /// Account + controller with the lookup on. [signIn] is the user's own
  /// Google sign-in; otherwise the session is "restored" via the stream.
  Future<(AccountController, CloudSyncController)> start(
    SqliteLocalStorage s,
    FakeCloudBackend cloud, {
    FakeAuth? auth,
    bool signIn = true,
    bool lookup = true,
  }) async {
    final gateway = auth ?? FakeAuth(_alice);
    final account = AccountController(
      gateway: gateway,
      boundAccount: _Bound(s),
    );
    final sync = CloudSyncController(
      engine: InitialSyncEngine(store: s.syncStore, backend: cloud),
      account: account,
      findRestorableBackup: lookup,
    );
    account.cloudSync = sync;
    await account.start();
    if (signIn) {
      await account.signIn();
    } else {
      gateway.users.add(_alice);
      for (var i = 0; i < 200 && account.phase != AccountPhase.signedIn; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    }
    await sync.waitForBackupLookup();
    return (account, sync);
  }

  group('backup lookup (controller)', () {
    test(
      'B: reinstall, sign-in, cloud 10 songs / 3 folders → offer + prompt',
      () async {
        final s = await launch();
        final cloud = _cloudWith();
        final (_, sync) = await start(s, cloud);

        expect(sync.phase, CloudSyncPhase.notConnected);
        final offer = sync.restoreOffer!;
        expect(offer.uid, _uid);
        expect(offer.cloud.songs, 10);
        expect(offer.cloud.folders, 3);
        expect(cloud.fetchCount, 1); // one read-only look
        expect(sync.takeRestorePrompt(), isNotNull);
        expect(sync.takeRestorePrompt(), isNull, reason: 'prompt only once');
        expect(sync.restoreOffer, isNotNull, reason: 'offer stays');
        sync.dispose();
      },
    );

    test('C: declining writes nothing anywhere', () async {
      final s = await launch();
      final cloud = _cloudWith();
      final tablesBefore = await dumpUserTables(dbOf(s));
      final metaBefore = await dumpSyncMeta(dbOf(s));
      final (_, sync) = await start(s, cloud);
      sync.takeRestorePrompt(); // shown, then "나중에": nothing else happens

      expect(await dumpUserTables(dbOf(s)), tablesBefore);
      expect(await dumpSyncMeta(dbOf(s)), metaBefore);
      expect(await boundUid(s), isNull);
      expect(cloud.commitCount, 0);
      expect(await File(cloudBackupPath).exists(), isFalse);
      expect(sync.phase, CloudSyncPhase.notConnected);
      expect(sync.restoreOffer?.cloud.songs, 10, reason: 'can restore later');
      sync.dispose();
    });

    test('D: 복원하기 = startSetup → Case B restore, bound, connected', () async {
      final s = await launch();
      final cloud = _cloudWith();
      final (account, sync) = await start(s, cloud);
      final version = sync.dataVersion;

      await sync.startSetup();
      expect(sync.phase, CloudSyncPhase.connected);
      expect((await s.songs.getAll()).length, 10);
      expect((await s.folders.getAll()).length, 3);
      expect(await boundUid(s), _uid);
      expect(
        await readSyncMeta(dbOf(s), SyncMetaKeys.initialSyncMode),
        InitialSyncMode.restore.storedName,
      );
      expect(account.linkStatus, AccountLinkStatus.sameAccount);
      expect(sync.restoreOffer, isNull);
      expect(sync.dataVersion, version + 1);
      expect(cloud.commitCount, 0, reason: 'restore uploads nothing');
      sync.dispose();
    });

    test('E: deleted cloud songs/folders are not counted', () async {
      final s = await launch();
      final cloud = _cloudWith(songs: 2, folders: 1)
        ..seed(_uid, CloudDocCodec.putSong(_songId(90), songData('삭제'), 1))
        ..seed(_uid, CloudDocCodec.deleteSong(_songId(90), 5))
        ..seed(_uid, CloudDocCodec.deleteSong(_songId(91), 5))
        ..seed(_uid, CloudDocCodec.deleteFolder(_folderId(90), 5));
      final (_, sync) = await start(s, cloud);
      expect(sync.restoreOffer!.cloud.songs, 2);
      expect(sync.restoreOffer!.cloud.folders, 1);
      sync.dispose();
    });

    test('E2: only deleted documents in the cloud → no offer', () async {
      final s = await launch();
      final cloud = FakeCloudBackend()
        ..seed(_uid, CloudDocCodec.deleteSong(_songId(1), 5))
        ..seed(_uid, CloudDocCodec.deleteFolder(_folderId(1), 5));
      final (_, sync) = await start(s, cloud);
      expect(sync.restoreOffer, isNull);
      expect(sync.takeRestorePrompt(), isNull);
      sync.dispose();
    });

    test(
      'F: local 0 + cloud 0 → no offer; setup still binds (Case C)',
      () async {
        final s = await launch();
        final cloud = FakeCloudBackend();
        final (_, sync) = await start(s, cloud);
        expect(sync.restoreOffer, isNull);
        expect(sync.takeRestorePrompt(), isNull);
        expect(sync.phase, CloudSyncPhase.notConnected);

        await sync.startSetup();
        expect(sync.phase, CloudSyncPhase.connected);
        expect(
          await readSyncMeta(dbOf(s), SyncMetaKeys.initialSyncMode),
          InitialSyncMode.bindOnly.storedName,
        );
        sync.dispose();
      },
    );

    test(
      'G: device has songs → no cloud read, no offer, merge flow as before',
      () async {
        final s = await launch();
        await addSong(s, '내 곡');
        final cloud = _cloudWith();
        final (_, sync) = await start(s, cloud);
        expect(cloud.fetchCount, 0);
        expect(sync.restoreOffer, isNull);
        expect(sync.takeRestorePrompt(), isNull);

        await sync.startSetup();
        expect(sync.phase, CloudSyncPhase.needsMergeDecision);
        expect(cloud.commitCount, 0);
        expect(await boundUid(s), isNull);
        sync.dispose();
      },
    );

    test(
      'H: device bound to another account → signed out, no lookup',
      () async {
        final s = await launch();
        await dbOf(s).insert('sync_meta', {
          'key': SyncMetaKeys.accountUid,
          'value': 'uid-other',
        });
        final cloud = _cloudWith();
        final (account, sync) = await start(s, cloud);
        expect(account.phase, AccountPhase.signedOut);
        expect(cloud.fetchCount, 0);
        expect(sync.restoreOffer, isNull);
        expect(await boundUid(s), 'uid-other');
        sync.dispose();
      },
    );

    test(
      'H: unfinished account deletion → no offer, nothing read or written',
      () async {
        final s = await launch();
        await (s.syncStore as AccountDeletionStore).markAccountDeletionStarted(
          _uid,
        );
        final cloud = _cloudWith();
        final (_, sync) = await start(s, cloud);
        expect(cloud.fetchCount, 0);
        expect(sync.restoreOffer, isNull);
        expect(cloud.commitCount, 0);
        sync.dispose();
      },
    );

    test('I: failed sign-in → no lookup', () async {
      final s = await launch();
      final cloud = _cloudWith();
      final (account, sync) = await start(s, cloud, auth: _FailingAuth());
      expect(account.phase, AccountPhase.signedOut);
      expect(cloud.fetchCount, 0);
      expect(sync.restoreOffer, isNull);
      sync.dispose();
    });

    test(
      'J: lookup offline → no crash, nothing changed, setup available',
      () async {
        final s = await launch();
        final cloud = _cloudWith()
          ..fetchError = const CloudSyncBackendException(
            CloudSyncErrorKind.network,
            'offline',
          );
        final metaBefore = await dumpSyncMeta(dbOf(s));
        final (_, sync) = await start(s, cloud);
        expect(sync.restoreOffer, isNull);
        expect(sync.findingBackup, isFalse);
        expect(sync.phase, CloudSyncPhase.notConnected);
        expect(await dumpSyncMeta(dbOf(s)), metaBefore);
        expect((await s.songs.getAll()), isEmpty);
        sync.dispose();
      },
    );

    test(
      'K: restore fails → not bound, local unchanged, retry works',
      () async {
        final s = await launch();
        final cloud = _cloudWith();
        final (_, sync) = await start(s, cloud);
        expect(sync.restoreOffer, isNotNull);

        cloud.fetchError = const CloudSyncBackendException(
          CloudSyncErrorKind.network,
          'offline',
        );
        await sync.startSetup();
        expect(sync.phase, CloudSyncPhase.failed);
        expect(await boundUid(s), isNull);
        expect(await s.songs.getAll(), isEmpty);

        cloud.fetchError = null;
        await sync.startSetup(); // existing "다시 시도"
        expect(sync.phase, CloudSyncPhase.connected);
        expect((await s.songs.getAll()).length, 10);
        expect(await boundUid(s), _uid);
        sync.dispose();
      },
    );

    test('restored session: offer for the account UI, but no prompt', () async {
      final s = await launch();
      final (_, sync) = await start(s, _cloudWith(), signIn: false);
      expect(sync.restoreOffer, isNotNull);
      expect(sync.takeRestorePrompt(), isNull);
      sync.dispose();
    });

    test('a local write drops the offer', () async {
      final s = await launch();
      final (_, sync) = await start(s, _cloudWith());
      sync.onLocalDataChanged();
      expect(sync.restoreOffer, isNull);
      sync.dispose();
    });

    test('lookup is off unless enabled (existing behaviour)', () async {
      final s = await launch();
      final cloud = _cloudWith();
      final (_, sync) = await start(s, cloud, lookup: false);
      expect(cloud.fetchCount, 0);
      expect(sync.restoreOffer, isNull);
      sync.dispose();
    });
  });

  // -------------------------------------------------------------------------
  group('empty song list UI', () {
    /// Lets real SQLite / fake-cloud work finish between frames.
    Future<void> settle(WidgetTester tester, [bool Function()? until]) async {
      for (var i = 0; i < 100; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
        if (until != null && until()) break;
      }
      await tester.pump();
    }

    testWidgets('A: fresh install, signed out → card with Google 계정 연결', (
      tester,
    ) async {
      final storage = InMemoryLocalStorage();
      await storage.init();
      final account = AccountController(
        gateway: FakeAuth(_alice),
        boundAccount: _NoBinding(),
      );
      await account.start();
      await tester.pumpWidget(
        MaterialApp(
          home: AppShell(storage: storage, account: account),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('노래가 없습니다.'), findsOneWidget);
      expect(find.byKey(const Key('songbookAccountCard')), findsOneWidget);
      expect(find.text('Google 계정 연결'), findsOneWidget);
      expect(find.byKey(const Key('cloudRestoreDialog')), findsNothing);
    });

    testWidgets('no account support → no card (Web/tests)', (tester) async {
      final storage = InMemoryLocalStorage();
      await storage.init();
      await tester.pumpWidget(MaterialApp(home: AppShell(storage: storage)));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('songbookAccountCard')), findsNothing);
    });

    testWidgets('B/C/D: sign in from the card → prompt with counts → 나중에 → '
        'restore from the card → songs shown, 지금 동기화', (tester) async {
      late SqliteLocalStorage s;
      late AccountController account;
      late CloudSyncController sync;
      final cloud = _cloudWith();
      await tester.runAsync(() async {
        s = await launch();
        account = AccountController(
          gateway: FakeAuth(_alice),
          boundAccount: _Bound(s),
        );
        sync = CloudSyncController(
          engine: InitialSyncEngine(store: s.syncStore, backend: cloud),
          account: account,
          manual: ManualSyncEngine(store: s.syncStore, backend: cloud),
          findRestorableBackup: true,
        );
        account.cloudSync = sync;
        await account.start();
      });
      await tester.pumpWidget(
        MaterialApp(
          home: AppShell(storage: s, account: account),
        ),
      );
      await settle(
        tester,
        () => find.text('Google 계정 연결').evaluate().isNotEmpty,
      );
      expect(find.byKey(const Key('songbookAccountSignIn')), findsOneWidget);

      await tester.tap(find.byKey(const Key('songbookAccountSignIn')));
      await settle(
        tester,
        () => find.byKey(const Key('cloudRestoreDialog')).evaluate().isNotEmpty,
      );
      expect(find.text('클라우드 백업을 찾았어요'), findsOneWidget);
      expect(find.text('노래 10곡'), findsOneWidget);
      expect(find.text('폴더 3개'), findsOneWidget);

      // 나중에: only closes.
      await tester.tap(find.byKey(const Key('cloudRestoreLater')));
      await settle(tester);
      expect(find.byKey(const Key('cloudRestoreDialog')), findsNothing);
      await tester.runAsync(() async {
        expect(await boundUid(s), isNull);
        expect(await s.songs.getAll(), isEmpty);
      });
      expect(cloud.commitCount, 0);
      expect(find.text('노래가 없습니다.'), findsOneWidget);
      expect(find.text('클라우드 백업이 있어요'), findsOneWidget);
      expect(find.text('노래 10곡 · 폴더 3개'), findsOneWidget);

      // Restore later from the card: the normal first connection.
      await tester.tap(find.byKey(const Key('cloudRestoreButton')));
      await settle(tester, () => sync.phase == CloudSyncPhase.connected);
      await settle(tester, () => find.text('10곡').evaluate().isNotEmpty);
      expect(sync.phase, CloudSyncPhase.connected);
      await tester.runAsync(() async {
        expect(await boundUid(s), _uid);
        expect((await s.songs.getAll()).length, 10);
        expect((await s.folders.getAll()).length, 3);
      });
      expect(find.text('노래가 없습니다.'), findsNothing);
      expect(find.text('10곡'), findsOneWidget); // header count
      expect(find.byKey(const Key('songbookAccountCard')), findsNothing);
      // The account sheet now shows the normal "지금 동기화" state.
      await tester.tap(find.byKey(const Key('accountButton')));
      await settle(tester);
      expect(find.text('백업 연결됨'), findsOneWidget);
      expect(find.byKey(const Key('cloudSyncNowButton')), findsOneWidget);
      expect(find.text('지금 동기화'), findsOneWidget);
      expect(find.byKey(const Key('cloudRestoreButton')), findsNothing);
      expect(find.byKey(const Key('cloudSetupButton')), findsNothing);
      expect(find.byKey(const Key('cloudRestoreDialog')), findsNothing);
      sync.dispose();
    });

    testWidgets('D: 복원하기 in the prompt restores right away', (tester) async {
      late SqliteLocalStorage s;
      late AccountController account;
      late CloudSyncController sync;
      final cloud = _cloudWith(songs: 4, folders: 2);
      await tester.runAsync(() async {
        s = await launch();
        account = AccountController(
          gateway: FakeAuth(_alice),
          boundAccount: _Bound(s),
        );
        sync = CloudSyncController(
          engine: InitialSyncEngine(store: s.syncStore, backend: cloud),
          account: account,
          findRestorableBackup: true,
        );
        account.cloudSync = sync;
        await account.start();
      });
      await tester.pumpWidget(
        MaterialApp(
          home: AppShell(storage: s, account: account),
        ),
      );
      await settle(
        tester,
        () => find.text('Google 계정 연결').evaluate().isNotEmpty,
      );
      await tester.tap(find.byKey(const Key('songbookAccountSignIn')));
      await settle(
        tester,
        () => find.byKey(const Key('cloudRestoreDialog')).evaluate().isNotEmpty,
      );
      await tester.tap(find.byKey(const Key('cloudRestoreConfirm')));
      await settle(tester, () => sync.phase == CloudSyncPhase.connected);
      await settle(tester, () => find.text('곡 1').evaluate().isNotEmpty);
      expect(sync.phase, CloudSyncPhase.connected);
      await tester.runAsync(() async {
        expect(await boundUid(s), _uid);
        expect((await s.songs.getAll()).length, 4);
      });
      expect(find.text('곡 1'), findsOneWidget);
      // No second prompt after the restore.
      expect(find.byKey(const Key('cloudRestoreDialog')), findsNothing);
      sync.dispose();
    });

    testWidgets('F: empty cloud → no prompt, card offers 클라우드 백업 설정', (
      tester,
    ) async {
      late SqliteLocalStorage s;
      late AccountController account;
      late CloudSyncController sync;
      await tester.runAsync(() async {
        s = await launch();
        account = AccountController(
          gateway: FakeAuth(_alice),
          boundAccount: _Bound(s),
        );
        sync = CloudSyncController(
          engine: InitialSyncEngine(
            store: s.syncStore,
            backend: FakeCloudBackend(),
          ),
          account: account,
          findRestorableBackup: true,
        );
        account.cloudSync = sync;
        await account.start();
      });
      await tester.pumpWidget(
        MaterialApp(
          home: AppShell(storage: s, account: account),
        ),
      );
      await settle(
        tester,
        () => find.text('Google 계정 연결').evaluate().isNotEmpty,
      );
      await tester.tap(find.byKey(const Key('songbookAccountSignIn')));
      await settle(
        tester,
        () => find.byKey(const Key('cloudSetupButton')).evaluate().isNotEmpty,
      );
      expect(find.byKey(const Key('cloudRestoreDialog')), findsNothing);
      expect(find.byKey(const Key('cloudSetupButton')), findsOneWidget);
      expect(find.text('클라우드 백업이 있어요'), findsNothing);
      sync.dispose();
    });

    testWidgets('J: lookup offline → no prompt, card still usable', (
      tester,
    ) async {
      late SqliteLocalStorage s;
      late AccountController account;
      late CloudSyncController sync;
      final cloud = _cloudWith()
        ..fetchError = const CloudSyncBackendException(
          CloudSyncErrorKind.network,
          'offline',
        );
      await tester.runAsync(() async {
        s = await launch();
        account = AccountController(
          gateway: FakeAuth(_alice),
          boundAccount: _Bound(s),
        );
        sync = CloudSyncController(
          engine: InitialSyncEngine(store: s.syncStore, backend: cloud),
          account: account,
          findRestorableBackup: true,
        );
        account.cloudSync = sync;
        await account.start();
      });
      await tester.pumpWidget(
        MaterialApp(
          home: AppShell(storage: s, account: account),
        ),
      );
      await settle(
        tester,
        () => find.text('Google 계정 연결').evaluate().isNotEmpty,
      );
      await tester.tap(find.byKey(const Key('songbookAccountSignIn')));
      await settle(
        tester,
        () => find.byKey(const Key('cloudSetupButton')).evaluate().isNotEmpty,
      );
      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('cloudRestoreDialog')), findsNothing);
      expect(find.byKey(const Key('cloudSetupButton')), findsOneWidget);
      sync.dispose();
    });

    testWidgets('H: blocked account → card shows the notice, no restore UI', (
      tester,
    ) async {
      late SqliteLocalStorage s;
      late AccountController account;
      late CloudSyncController sync;
      final cloud = _cloudWith();
      await tester.runAsync(() async {
        s = await launch();
        await dbOf(s).insert('sync_meta', {
          'key': SyncMetaKeys.accountUid,
          'value': 'uid-other',
        });
        account = AccountController(
          gateway: FakeAuth(_alice),
          boundAccount: _Bound(s),
        );
        sync = CloudSyncController(
          engine: InitialSyncEngine(store: s.syncStore, backend: cloud),
          account: account,
          findRestorableBackup: true,
        );
        account.cloudSync = sync;
        await account.start();
      });
      await tester.pumpWidget(
        MaterialApp(
          home: AppShell(storage: s, account: account),
        ),
      );
      await settle(
        tester,
        () => find.text('Google 계정 연결').evaluate().isNotEmpty,
      );
      await tester.tap(find.byKey(const Key('songbookAccountSignIn')));
      await settle(tester);
      expect(account.phase, AccountPhase.signedOut);
      expect(find.textContaining('다른 Google 계정의 백업에 연결'), findsOneWidget);
      expect(find.byKey(const Key('cloudRestoreDialog')), findsNothing);
      expect(find.byKey(const Key('cloudRestoreButton')), findsNothing);
      expect(cloud.fetchCount, 0);
      sync.dispose();
    });
  });
}
