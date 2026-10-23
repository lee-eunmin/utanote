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
import 'package:utanote/sync/cloud_sync_controller.dart';
import 'package:utanote/sync/initial_sync_engine.dart';
import 'package:utanote/sync/local_sync_store.dart';
import 'package:utanote/ui/backup_prompt.dart';

import 'support/sync_fakes.dart';

/// Phase B-4B: the start-up "노래를 안전하게 백업할까요?" prompt for users
/// whose device isn't connected to a cloud account yet.

const _alice = AccountUser(uid: 'uid-alice', email: 'alice@example.com');
const _title = '노래를 안전하게 백업할까요?';
const _day = Duration(days: 1);

class _MemoryPrefs implements BackupPromptPrefs {
  int? value;

  @override
  Future<int?> snoozedAtMs() async => value;

  @override
  Future<void> setSnoozedAtMs(int utcMs) async => value = utcMs;
}

class _Bound implements BoundAccountSource {
  String? uid;

  @override
  Future<String?> readBoundAccountUid() async => uid;
}

class _CountingAuth extends FakeAuth {
  int signIns = 0;
  int signOuts = 0;
  bool available = true;

  _CountingAuth() : super(_alice);

  @override
  Future<bool> initialize() async => available;

  @override
  Future<AccountUser> signInWithGoogle() {
    signIns++;
    return super.signInWithGoogle();
  }

  @override
  Future<void> signOut() {
    signOuts++;
    return super.signOut();
  }
}

/// Never reached in these tests (no cloud work happens in them).
class _UnusedStore implements LocalSyncStore {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

final _when = DateTime.parse('2024-01-01T00:00:00.000');

Song _song(String title) => Song(
    karaokeType: 'TJ',
    songNumber: '1',
    title: title,
    createdAt: _when,
    updatedAt: _when);

/// Lets real SQLite work (outside the fake clock) and the UI catch up.
Future<void> settleReal(WidgetTester tester, bool Function() done) async {
  for (var i = 0; i < 40 && !done(); i++) {
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 25)));
    await tester.pump(const Duration(milliseconds: 50));
  }
  await tester.pumpAndSettle();
}

void main() {
  late _MemoryPrefs prefs;
  late _Bound bound;
  late _CountingAuth auth;
  var nowMs = 1700000000000;

  setUp(() {
    prefs = _MemoryPrefs();
    bound = _Bound();
    auth = _CountingAuth();
  });

  Future<InMemoryLocalStorage> storageWith(int songs) async {
    final s = InMemoryLocalStorage();
    await s.init();
    for (var i = 0; i < songs; i++) {
      await s.songs.create(_song('곡 $i'));
    }
    return s;
  }

  AccountController newAccount() {
    final account = AccountController(gateway: auth, boundAccount: bound);
    account.cloudSync = CloudSyncController(
      engine: InitialSyncEngine(store: _UnusedStore(), backend: FakeCloudBackend()),
      account: account,
    );
    return account;
  }

  Future<AccountController> launch(
    WidgetTester tester,
    InMemoryLocalStorage storage, {
    bool signedIn = false,
  }) async {
    final account = newAccount();
    await tester.runAsync(() async {
      await account.start();
      if (signedIn) await account.signIn();
    });
    await tester.pumpWidget(UtaNoteApp(
      storage: storage,
      account: account,
      backupPromptPrefs: prefs,
      backupPromptDelay: Duration.zero,
      backupPromptNow: () => nowMs,
    ));
    await tester.pumpAndSettle();
    return account;
  }

  testWidgets('unconnected + songs saved: shown with "Google 계정 연결"',
      (tester) async {
    final account = await launch(tester, await storageWith(1));
    expect(find.text(_title), findsOneWidget);
    expect(find.text('Google 계정 연결'), findsOneWidget);
    expect(find.text('나중에'), findsOneWidget);
    expect(find.textContaining('삭제되지 않아요'), findsOneWidget);
    account.cloudSync!.dispose();
  });

  testWidgets('no songs yet: not shown', (tester) async {
    final account = await launch(tester, await storageWith(0));
    expect(find.text(_title), findsNothing);
    account.cloudSync!.dispose();
  });

  testWidgets('already connected (account_uid): never shown', (tester) async {
    bound.uid = 'uid-alice';
    final account = await launch(tester, await storageWith(3));
    expect(find.text(_title), findsNothing);
    account.cloudSync!.dispose();
  });

  testWidgets('sign-in unavailable (no Firebase): not shown', (tester) async {
    auth.available = false;
    final account = await launch(tester, await storageWith(3));
    expect(find.text(_title), findsNothing);
    account.cloudSync!.dispose();
  });

  testWidgets('"나중에": not again for 7 days, then shown again',
      (tester) async {
    final storage = await storageWith(2);
    var account = await launch(tester, storage);
    await tester.tap(find.byKey(const Key('backupPromptLater')));
    await tester.pumpAndSettle();
    expect(find.text(_title), findsNothing);
    expect(prefs.value, nowMs);
    account.cloudSync!.dispose();

    nowMs += (_day * 6).inMilliseconds;
    await tester.pumpWidget(const SizedBox());
    account = await launch(tester, storage);
    expect(find.text(_title), findsNothing);
    account.cloudSync!.dispose();

    nowMs += (_day * 2).inMilliseconds; // 8 days after "나중에"
    await tester.pumpWidget(const SizedBox());
    account = await launch(tester, storage);
    expect(find.text(_title), findsOneWidget);
    account.cloudSync!.dispose();
  });

  testWidgets('closing or "나중에" changes nothing: no sign-in, no binding, '
      'same songs and folders', (tester) async {
    final storage = await storageWith(2);
    await storage.folders
        .create(Folder(name: '폴더', createdAt: _when, updatedAt: _when));
    final songsBefore = (await storage.songs.getAll()).map((s) => s.toMap());
    final foldersBefore =
        (await storage.folders.getAll()).map((f) => f.toMap());
    final account = await launch(tester, storage);
    expect(find.text(_title), findsOneWidget);
    // Close by tapping outside the sheet.
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(find.text(_title), findsNothing);
    expect(auth.signIns, 0);
    expect(auth.signOuts, 0);
    expect(bound.uid, isNull);
    expect(account.phase, AccountPhase.signedOut);
    expect((await storage.songs.getAll()).map((s) => s.toMap()), songsBefore);
    expect(
        (await storage.folders.getAll()).map((f) => f.toMap()), foldersBefore);
    expect(prefs.value, nowMs); // closing counts as "나중에"
    account.cloudSync!.dispose();
  });

  testWidgets('"Google 계정 연결": signs in, then opens the backup setup',
      (tester) async {
    final account = await launch(tester, await storageWith(1));
    await tester.tap(find.byKey(const Key('backupPromptConnect')));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();
    expect(auth.signIns, 1);
    expect(account.phase, AccountPhase.signedIn);
    // The account sheet is open with the first-connection flow started.
    expect(find.text('계정'), findsOneWidget);
    expect(account.cloudSync!.phase, isNot(CloudSyncPhase.notConnected));
    account.cloudSync!.dispose();
  });

  testWidgets('signed in but not connected: "클라우드 백업 설정", no account '
      'picker again', (tester) async {
    final account = await launch(tester, await storageWith(1), signedIn: true);
    expect(find.text(_title), findsOneWidget);
    expect(find.text('클라우드 백업 설정'), findsOneWidget);
    expect(find.text('Google 계정 연결'), findsNothing);
    final signInsBefore = auth.signIns;
    await tester.tap(find.byKey(const Key('backupPromptConnect')));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();
    expect(auth.signIns, signInsBefore);
    expect(find.text('계정'), findsOneWidget);
    expect(account.cloudSync!.phase, isNot(CloudSyncPhase.notConnected));
    account.cloudSync!.dispose();
  });

  testWidgets('evaluate: songs/binding/snooze rules', (tester) async {
    await tester.runAsync(() async {
      final storage = await storageWith(1);
      final account = newAccount();
      await account.start();
      Future<BackupPromptAction?> eval() => evaluateBackupPrompt(
            account: account,
            storage: storage,
            prefs: prefs,
            nowMs: nowMs,
          );
      expect(await eval(), BackupPromptAction.connectGoogle);
      prefs.value = nowMs - (_day * 7).inMilliseconds + 1;
      expect(await eval(), isNull);
      prefs.value = nowMs - (_day * 7).inMilliseconds;
      expect(await eval(), BackupPromptAction.connectGoogle);
      bound.uid = 'uid-alice';
      expect(await eval(), isNull);
      account.cloudSync!.dispose();
    });
  });

  // -------------------------------------------------------------------------
  group('with real SQLite', () {
    final opened = <SqliteLocalStorage>[];

    setUpAll(() async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      final dir = await Directory.systemTemp.createTemp('utanote_prompt_');
      await databaseFactory.setDatabasesPath(dir.path);
    });

    tearDown(() async {
      for (final s in opened) {
        await s.close();
        await databaseFactory
            .deleteDatabase(p.join(await getDatabasesPath(), 'songbook.db'));
      }
      opened.clear();
    });

    testWidgets('after a successful connection the prompt never shows again',
        (tester) async {
      late SqliteLocalStorage s;
      late AccountController account;
      final cloud = FakeCloudBackend();
      await tester.runAsync(() async {
        s = SqliteLocalStorage();
        await s.init();
        opened.add(s);
        await s.songs.create(_song('내 곡'));
        account = AccountController(gateway: auth, boundAccount: _SqliteBound(s));
        account.cloudSync = CloudSyncController(
          engine: InitialSyncEngine(store: s.syncStore, backend: cloud),
          account: account,
        );
        await account.start();
        await account.signIn();
      });
      await tester.pumpWidget(UtaNoteApp(
        storage: s,
        account: account,
        backupPromptPrefs: prefs,
        backupPromptDelay: Duration.zero,
        backupPromptNow: () => nowMs,
      ));
      await settleReal(
          tester, () => find.text('클라우드 백업 설정').evaluate().isNotEmpty);
      expect(find.text('클라우드 백업 설정'), findsOneWidget);
      await tester.tap(find.byKey(const Key('backupPromptConnect')));
      for (var i = 0; i < 20; i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 50)));
        await tester.pump();
        if (account.cloudSync!.phase == CloudSyncPhase.connected) break;
      }
      expect(account.cloudSync!.phase, CloudSyncPhase.connected);
      expect(find.text('백업 연결됨'), findsOneWidget);
      late String? boundUid;
      await tester.runAsync(() async {
        boundUid = await readSyncMeta(
            s.databaseForTesting, SyncMetaKeys.accountUid);
      });
      expect(boundUid, 'uid-alice');

      // Next launch, even long after: never again.
      nowMs += (_day * 30).inMilliseconds;
      prefs.value = null;
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(UtaNoteApp(
        storage: s,
        account: account,
        backupPromptPrefs: prefs,
        backupPromptDelay: Duration.zero,
        backupPromptNow: () => nowMs,
      ));
      await settleReal(tester, () => false);
      expect(find.text(_title), findsNothing);
      account.cloudSync!.dispose();
    });
  });
}

class _SqliteBound implements BoundAccountSource {
  final SqliteLocalStorage storage;
  _SqliteBound(this.storage);

  @override
  Future<String?> readBoundAccountUid() => storage.readBoundAccountUid();
}
