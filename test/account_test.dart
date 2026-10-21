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

/// Phase B-2: Google sign-in state handling. Sign-in must never change
/// local data or `sync_meta.account_uid`.

const _alice = AccountUser(uid: 'uid-alice', email: 'alice@example.com');
const _bob = AccountUser(uid: 'uid-bob', email: 'bob@example.com');

class FakeAuthGateway implements AuthGateway {
  /// What initialize() does: return a value, or throw.
  FutureOr<bool> Function() onInitialize = () => true;

  /// What signInWithGoogle() does: return a user, or throw.
  Future<AccountUser> Function() onSignIn = () async => _alice;

  final users = StreamController<AccountUser?>.broadcast();
  int signOutCalls = 0;

  /// Mirrors FirebaseAuth: a successful sign-in also emits on the stream,
  /// and sign-out emits null.
  bool emitOnChange = true;

  @override
  Future<bool> initialize() async => onInitialize();

  @override
  Stream<AccountUser?> userChanges() => users.stream;

  @override
  Future<AccountUser> signInWithGoogle() async {
    final user = await onSignIn();
    if (emitOnChange) users.add(user);
    return user;
  }

  @override
  Future<void> signOut() async {
    signOutCalls++;
    if (emitOnChange) users.add(null);
  }
}

class FakeBoundAccount implements BoundAccountSource {
  String? uid;
  Object? error;
  int reads = 0;

  @override
  Future<String?> readBoundAccountUid() async {
    reads++;
    if (error != null) throw error!;
    return uid;
  }
}

class SqliteBoundAccount implements BoundAccountSource {
  final SqliteLocalStorage storage;
  SqliteBoundAccount(this.storage);

  @override
  Future<String?> readBoundAccountUid() => storage.readBoundAccountUid();
}

Future<void> settle() => Future<void>.delayed(Duration.zero);

void main() {
  late FakeAuthGateway gateway;
  late FakeBoundAccount bound;

  AccountController newController() =>
      AccountController(gateway: gateway, boundAccount: bound);

  setUp(() {
    gateway = FakeAuthGateway();
    bound = FakeBoundAccount();
  });

  group('startup', () {
    test('Firebase not configured (initialize returns false) -> unavailable', () async {
      gateway.onInitialize = () => false;
      final c = newController();
      await c.start();
      expect(c.phase, AccountPhase.unavailable);
      expect(c.canSync, isFalse);
    });

    test('initialize throwing does not escape -> unavailable', () async {
      gateway.onInitialize = () => throw StateError('no google-services.json');
      final c = newController();
      await expectLater(c.start(), completes);
      expect(c.phase, AccountPhase.unavailable);
    });

    test('ready with no session -> signed out', () async {
      final c = newController();
      await c.start();
      expect(c.phase, AccountPhase.signedOut);
      expect(c.user, isNull);
    });

    test('a session restored at startup is shown as signed in', () async {
      final c = newController();
      await c.start();
      gateway.users.add(_alice);
      await settle();
      await settle();
      expect(c.phase, AccountPhase.signedIn);
      expect(c.user, _alice);
      expect(c.linkStatus, AccountLinkStatus.unlinked);
    });

    test('start() is idempotent', () async {
      var inits = 0;
      gateway.onInitialize = () {
        inits++;
        return true;
      };
      final c = newController();
      await Future.wait([c.start(), c.start()]);
      await c.start();
      expect(inits, 1);
    });
  });

  group('sign-in', () {
    test('success: uid and email available, unlinked device may sync', () async {
      final c = newController();
      await c.start();
      final phases = <AccountPhase>[];
      c.addListener(() => phases.add(c.phase));
      await c.signIn();
      await settle();
      expect(phases.first, AccountPhase.signingIn);
      expect(c.phase, AccountPhase.signedIn);
      expect(c.user!.uid, 'uid-alice');
      expect(c.user!.email, 'alice@example.com');
      expect(c.linkStatus, AccountLinkStatus.unlinked);
      expect(c.canSync, isTrue);
      expect(c.message, isNull);
    });

    test('works whether or not the auth stream also reports the user', () async {
      gateway.emitOnChange = false;
      final c = newController();
      await c.start();
      await c.signIn();
      expect(c.phase, AccountPhase.signedIn);
      expect(c.user, _alice);
    });

    test('cancelled: back to signed out, no error message', () async {
      gateway.onSignIn = () async => throw const AccountSignInCancelled();
      final c = newController();
      await c.start();
      await c.signIn();
      expect(c.phase, AccountPhase.signedOut);
      expect(c.message, isNull);
      expect(c.user, isNull);
    });

    test('cancel still works if the stream sends "no user" meanwhile', () async {
      final picker = Completer<AccountUser>();
      gateway.onSignIn = () => picker.future;
      final c = newController();
      await c.start();
      final signingIn = c.signIn();
      await settle();
      expect(c.phase, AccountPhase.signingIn);
      gateway.users.add(null);
      await settle();
      expect(c.phase, AccountPhase.signingIn);
      picker.completeError(const AccountSignInCancelled());
      await signingIn;
      expect(c.phase, AccountPhase.signedOut);
    });

    test('failure: back to signed out with the user-facing message', () async {
      gateway.onSignIn = () async =>
          throw const AccountSignInFailure('네트워크 연결을 확인한 뒤 다시 시도해 주세요.');
      final c = newController();
      await c.start();
      await c.signIn();
      expect(c.phase, AccountPhase.signedOut);
      expect(c.message, '네트워크 연결을 확인한 뒤 다시 시도해 주세요.');
    });

    test('unexpected error: generic message, never a crash', () async {
      gateway.onSignIn = () async => throw Exception('boom');
      final c = newController();
      await c.start();
      await expectLater(c.signIn(), completes);
      expect(c.phase, AccountPhase.signedOut);
      expect(c.message, isNotNull);
    });

    test('a later successful sign-in clears the previous error', () async {
      var fail = true;
      gateway.onSignIn = () async {
        if (fail) throw const AccountSignInFailure('실패');
        return _alice;
      };
      final c = newController();
      await c.start();
      await c.signIn();
      expect(c.message, '실패');
      fail = false;
      await c.signIn();
      expect(c.phase, AccountPhase.signedIn);
      expect(c.message, isNull);
    });

    test('sign-in is ignored when unavailable', () async {
      gateway.onInitialize = () => false;
      var called = false;
      gateway.onSignIn = () async {
        called = true;
        return _alice;
      };
      final c = newController();
      await c.start();
      await c.signIn();
      expect(called, isFalse);
      expect(c.phase, AccountPhase.unavailable);
    });
  });

  group('sign-out', () {
    test('ends the session only', () async {
      final c = newController();
      await c.start();
      await c.signIn();
      await c.signOut();
      await settle();
      expect(gateway.signOutCalls, 1);
      expect(c.phase, AccountPhase.signedOut);
      expect(c.user, isNull);
      expect(c.canSync, isFalse);
    });

    test('a failing sign-out still leaves the app signed out, no crash', () async {
      final c = AccountController(
        gateway: _ThrowingSignOutGateway(),
        boundAccount: bound,
      );
      await c.start();
      await c.signIn();
      await expectLater(c.signOut(), completes);
      expect(c.phase, AccountPhase.signedOut);
    });
  });

  group('account link policy', () {
    test('evaluateAccountLink', () {
      expect(evaluateAccountLink(boundUid: null, signedInUid: 'a'),
          AccountLinkStatus.unlinked);
      expect(evaluateAccountLink(boundUid: '', signedInUid: 'a'),
          AccountLinkStatus.unlinked);
      expect(evaluateAccountLink(boundUid: 'a', signedInUid: 'a'),
          AccountLinkStatus.sameAccount);
      expect(evaluateAccountLink(boundUid: 'a', signedInUid: 'b'),
          AccountLinkStatus.otherAccount);
    });

    test('bound to the same account: allowed', () async {
      bound.uid = 'uid-alice';
      final c = newController();
      await c.start();
      await c.signIn();
      expect(c.phase, AccountPhase.signedIn);
      expect(c.linkStatus, AccountLinkStatus.sameAccount);
      expect(c.canSync, isTrue);
    });

    test('bound to another account: signed straight back out, blocked', () async {
      bound.uid = 'uid-alice';
      gateway.onSignIn = () async => _bob;
      final c = newController();
      await c.start();
      await c.signIn();
      await settle();
      expect(c.phase, AccountPhase.signedOut);
      expect(c.user, isNull);
      expect(c.canSync, isFalse);
      expect(gateway.signOutCalls, 1);
      expect(c.message, contains('다른 Google 계정'));
      expect(bound.uid, 'uid-alice'); // binding untouched
    });

    test('restored session for another account is blocked too', () async {
      bound.uid = 'uid-alice';
      final c = newController();
      await c.start();
      gateway.users.add(_bob);
      await settle();
      await settle();
      expect(c.phase, AccountPhase.signedOut);
      expect(gateway.signOutCalls, 1);
      expect(c.canSync, isFalse);
    });

    test('binding unreadable: treated as a mismatch (nothing may sync)', () async {
      bound.error = StateError('db closed');
      final c = newController();
      await c.start();
      await c.signIn();
      expect(c.phase, AccountPhase.signedOut);
      expect(c.canSync, isFalse);
    });
  });

  // -----------------------------------------------------------------------
  // Real SQLite: sign-in/out never changes local data or the binding.
  // -----------------------------------------------------------------------
  group('local SQLite data is untouched', () {
    late SqliteLocalStorage storage;
    late String dbPath;

    setUpAll(() async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      final dir = await Directory.systemTemp.createTemp('utanote_account_test_');
      await databaseFactory.setDatabasesPath(dir.path);
      dbPath = p.join(dir.path, 'songbook.db');
    });

    setUp(() async {
      await databaseFactory.deleteDatabase(dbPath);
      storage = SqliteLocalStorage();
      await storage.init();
      final now = DateTime.parse('2024-05-05T05:05:05.000');
      final a = await storage.songs.create(Song(
        karaokeType: 'TJ', songNumber: '1', title: '곡A',
        favorite: true, practiceStatus: '완료', searchAliases: const ['별칭'],
        createdAt: now, updatedAt: now,
      ));
      final b = await storage.songs.create(Song(
        karaokeType: 'KY', songNumber: '2', title: '곡B', memo: '메모',
        createdAt: now, updatedAt: now,
      ));
      final f = await storage.folders.create(
          Folder(name: '폴더', createdAt: now, updatedAt: now));
      await storage.folders.addSong(f.id!, a.id!);
      await storage.folders.addSong(f.id!, b.id!);
      await storage.folders.removeSong(f.id!, b.id!); // tombstone
      // Half of the rows "already synced", to prove nothing flips them.
      await storage.databaseForTesting.update('songs', {'sync_dirty': 0},
          where: 'id = ?', whereArgs: [a.id]);
    });

    tearDown(() async {
      await storage.close();
      await databaseFactory.deleteDatabase(dbPath);
    });

    Future<Map<String, Object?>> snapshot() async {
      final db = storage.databaseForTesting;
      return {
        for (final t in ['songs', 'folders', 'folder_songs', 'sync_tombstones', 'sync_meta'])
          t: await db.query(t, orderBy: 'rowid'),
        'version': await db.getVersion(),
      };
    }

    test('sign-in and sign-out leave every table byte-identical', () async {
      final before = await snapshot();
      final c = AccountController(
        gateway: gateway,
        boundAccount: SqliteBoundAccount(storage),
      );
      await c.start();
      await c.signIn();
      expect(c.phase, AccountPhase.signedIn);
      expect(await snapshot(), before);
      // Signing in does NOT bind the device (that happens in B-3).
      expect(await readSyncMeta(storage.databaseForTesting, SyncMetaKeys.accountUid),
          isNull);

      await c.signOut();
      await settle();
      expect(await snapshot(), before);
      expect((await storage.songs.getAll()).length, 2);
    });

    test('existing binding is kept through sign-out and a blocked account', () async {
      await writeSyncMeta(
          storage.databaseForTesting, SyncMetaKeys.accountUid, 'uid-alice');
      final before = await snapshot();
      final c = AccountController(
        gateway: gateway,
        boundAccount: SqliteBoundAccount(storage),
      );
      await c.start();

      await c.signIn(); // alice: same account
      expect(c.linkStatus, AccountLinkStatus.sameAccount);
      await c.signOut();
      await settle();
      expect(await snapshot(), before);

      gateway.onSignIn = () async => _bob; // other account: blocked
      await c.signIn();
      await settle();
      expect(c.phase, AccountPhase.signedOut);
      expect(await snapshot(), before);
      expect(await storage.readBoundAccountUid(), 'uid-alice');
    });

    test('readBoundAccountUid treats an empty value as unbound', () async {
      expect(await storage.readBoundAccountUid(), isNull);
      await writeSyncMeta(storage.databaseForTesting, SyncMetaKeys.accountUid, '');
      expect(await storage.readBoundAccountUid(), isNull);
    });
  });

  // -----------------------------------------------------------------------
  // UI.
  // -----------------------------------------------------------------------
  group('account UI', () {
    Future<InMemoryLocalStorage> memoryStorage() async {
      final s = InMemoryLocalStorage();
      await s.init();
      return s;
    }

    testWidgets('no account controller (Web/tests): no account button', (tester) async {
      await tester.pumpWidget(UtaNoteApp(storage: await memoryStorage()));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('accountButton')), findsNothing);
      expect(find.byKey(const Key('addSongButton')), findsOneWidget);
    });

    testWidgets('Firebase unavailable: app works, no account button', (tester) async {
      gateway.onInitialize = () => throw StateError('not configured');
      final c = newController();
      await tester.runAsync(c.start);
      await tester.pumpWidget(UtaNoteApp(storage: await memoryStorage(), account: c));
      await tester.pumpAndSettle();
      expect(c.phase, AccountPhase.unavailable);
      expect(find.byKey(const Key('accountButton')), findsNothing);
      expect(find.text('노래가 없습니다.'), findsOneWidget);
    });

    testWidgets('sign in shows email/uid; sign out returns to the button', (tester) async {
      final c = newController();
      await tester.runAsync(c.start);
      await tester.pumpWidget(UtaNoteApp(storage: await memoryStorage(), account: c));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('accountButton')));
      await tester.pumpAndSettle();
      expect(find.text('Google로 로그인'), findsOneWidget);

      await tester.tap(find.byKey(const Key('googleSignInButton')));
      await tester.pumpAndSettle();
      expect(find.text('alice@example.com'), findsOneWidget);
      expect(find.text('UID uid-alice'), findsOneWidget);

      await tester.tap(find.byKey(const Key('signOutButton')));
      await tester.pumpAndSettle();
      expect(find.text('Google로 로그인'), findsOneWidget);
      expect(find.text('alice@example.com'), findsNothing);
      expect(gateway.signOutCalls, 1);
    });

    testWidgets('failed sign-in shows the message in the sheet', (tester) async {
      gateway.onSignIn = () async => throw const AccountSignInFailure('로그인 설정에 문제가 있어요.');
      final c = newController();
      await tester.runAsync(c.start);
      await tester.pumpWidget(UtaNoteApp(storage: await memoryStorage(), account: c));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('accountButton')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('googleSignInButton')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('accountMessage')), findsOneWidget);
      expect(find.text('로그인 설정에 문제가 있어요.'), findsOneWidget);
      expect(find.text('Google로 로그인'), findsOneWidget);
    });
  });
}

class _ThrowingSignOutGateway extends FakeAuthGateway {
  @override
  Future<void> signOut() async => throw StateError('sign-out failed');
}
