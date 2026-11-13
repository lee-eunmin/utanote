import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:utanote/account/account_controller.dart';
import 'package:utanote/account/account_deletion.dart';
import 'package:utanote/account/auth_gateway.dart';
import 'package:utanote/config/account_links.dart';
import 'package:utanote/sync/account_data_deletion.dart';
import 'package:utanote/sync/cloud_sync_backend.dart';
import 'package:utanote/sync/cloud_sync_controller.dart';
import 'package:utanote/sync/initial_sync_engine.dart';
import 'package:utanote/sync/local_sync_store.dart';
import 'package:utanote/sync/manual_sync.dart';
import 'package:utanote/theme/app_theme.dart';
import 'package:utanote/ui/external_link.dart';
import 'package:utanote/ui/widgets/account_button.dart';

import 'support/sync_fakes.dart';

/// Phase B-5 account sheet: entry, confirmation, cancel, progress result,
/// unfinished-deletion resume. Pure fakes (no SQLite).

const _alice = AccountUser(uid: 'uid-alice', email: 'alice@example.com');

class _NoBinding implements BoundAccountSource {
  @override
  Future<String?> readBoundAccountUid() async => null;
}

class _MemStore implements AccountDeletionStore {
  PendingAccountDeletion? pending;
  int finished = 0;

  @override
  Future<PendingAccountDeletion?> readPendingAccountDeletion() async =>
      pending;

  @override
  Future<void> markAccountDeletionStarted(String uid) async {
    pending ??= PendingAccountDeletion(
      uid: uid,
      stage: AccountDeletionStage.blocking,
    );
  }

  @override
  Future<void> recordAccountDeletionProgress(
    String uid, {
    AccountDeletionStage? stage,
    int? deletedDocs,
  }) async {
    final p = pending;
    if (p == null || p.uid != uid) return;
    pending = PendingAccountDeletion(
      uid: uid,
      stage: stage != null && stage.index > p.stage.index ? stage : p.stage,
      deletedDocs: deletedDocs ?? p.deletedDocs,
    );
  }

  @override
  Future<void> cancelAccountDeletion(String uid) async {
    if (pending?.stage != AccountDeletionStage.blocking) {
      throw StateError('not cancellable');
    }
    pending = null;
  }

  @override
  Future<void> finishAccountDeletion(String uid) async {
    finished++;
    pending = null;
  }
}

void main() {
  late FakeAuth auth;
  late AccountController account;
  late FakeDeletionAuth deletionAuth;
  late FakeCloudBackend cloud;
  late FakeCloudEraser eraser;
  late _MemStore store;
  late AccountDeletionController deletion;

  Future<void> setUpWorld(WidgetTester tester, {PendingAccountDeletion? pending}) async {
    auth = FakeAuth(_alice);
    account = AccountController(gateway: auth, boundAccount: _NoBinding());
    deletionAuth = FakeDeletionAuth(_alice)..onDeleted = () => auth.users.add(null);
    cloud = FakeCloudBackend();
    cloud.seed(_alice.uid, CloudDocCodec.putSong('s1', songData('곡'), 1));
    eraser = FakeCloudEraser(cloud);
    store = _MemStore()..pending = pending;
    deletion = AccountDeletionController(
      account: account,
      auth: deletionAuth,
      store: store,
      eraser: eraser,
    );
    account.deletion = deletion;
    await deletion.load();
    await account.start();
    auth.users.add(_alice);
    await tester.pumpAndSettle();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(child: AccountSheet(account: account)),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('signed in: delete entry opens the confirmation', (tester) async {
    await setUpWorld(tester);
    expect(find.text('계정 및 클라우드 데이터 삭제'), findsOneWidget);

    await tester.tap(find.byKey(const Key('accountDeleteButton')));
    await tester.pumpAndSettle();
    expect(find.text('계정과 클라우드 백업을 삭제할까요?'), findsOneWidget);
    expect(find.textContaining('Google 로그인 계정 정보가 삭제돼요'), findsOneWidget);
    expect(find.textContaining('백업된 노래와 폴더 데이터가 삭제돼요'), findsOneWidget);
    expect(find.textContaining('이 기기에 저장된 노래와 폴더는 그대로'), findsOneWidget);
    expect(find.textContaining('복구할 수 없어요'), findsOneWidget);
    expect(find.textContaining('새 백업을 만들 수 있어요'), findsOneWidget);
    expect(find.byKey(const Key('accountDeleteCancel')), findsOneWidget);
    expect(find.text('계정 및 백업 삭제'), findsOneWidget);

    // 취소: nothing happens.
    await tester.tap(find.byKey(const Key('accountDeleteCancel')));
    await tester.pumpAndSettle();
    expect(find.text('계정과 클라우드 백업을 삭제할까요?'), findsNothing);
    expect(deletionAuth.reauthCalls, 0);
    expect(eraser.calls, 0);
    expect(account.phase, AccountPhase.signedIn);
  });

  testWidgets('confirm: deletes and shows the signed-out result', (tester) async {
    await setUpWorld(tester);
    await tester.tap(find.byKey(const Key('accountDeleteButton')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('accountDeleteConfirm')));
    await tester.pumpAndSettle();

    expect(deletionAuth.reauthCalls, 1);
    expect(cloud.docCount(_alice.uid, CloudCollections.songs), 0);
    expect(deletionAuth.deleteCalls, 1);
    expect(store.finished, 1);
    expect(account.phase, AccountPhase.signedOut);
    expect(find.byKey(const Key('accountDeletedNotice')), findsOneWidget);
    expect(find.byKey(const Key('googleSignInButton')), findsOneWidget);
    expect(find.byKey(const Key('accountDeleteButton')), findsNothing);
  });

  testWidgets('failure message is shown and the entry stays', (tester) async {
    await setUpWorld(tester);
    deletionAuth.reauthError = const AccountSignInFailure('로그인하지 못했어요.');
    await tester.tap(find.byKey(const Key('accountDeleteButton')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('accountDeleteConfirm')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('accountDeletionMessage')), findsOneWidget);
    expect(find.textContaining('아무것도 삭제하지 않았어요'), findsOneWidget);
    expect(find.byKey(const Key('accountDeleteButton')), findsOneWidget);
    expect(cloud.docCount(_alice.uid, CloudCollections.songs), 1);
  });

  testWidgets('unfinished deletion: resume without asking again', (tester) async {
    await setUpWorld(
      tester,
      pending: const PendingAccountDeletion(
        uid: 'uid-alice',
        stage: AccountDeletionStage.cloudDeleted,
      ),
    );
    expect(find.byKey(const Key('accountDeletionPendingNotice')), findsOneWidget);
    expect(find.text('계정 삭제 계속하기'), findsOneWidget);
    await tester.tap(find.byKey(const Key('accountDeletionResumeButton')));
    await tester.pumpAndSettle();
    expect(find.text('계정과 클라우드 백업을 삭제할까요?'), findsNothing);
    expect(deletionAuth.reauthCalls, 1);
    expect(deletionAuth.deleteCalls, 1);
    expect(account.phase, AccountPhase.signedOut);
  });

  testWidgets('signed out: no delete entry', (tester) async {
    await setUpWorld(tester);
    await account.signOut();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('accountDeleteButton')), findsNothing);
    expect(find.byKey(const Key('googleSignInButton')), findsOneWidget);
  });

  // --- External links (privacy policy, deletion request page) -------------

  group('external links', () {
    late List<Uri> opened;
    var launchResult = true;
    Object? launchError;

    setUp(() {
      opened = [];
      launchResult = true;
      launchError = null;
      externalUrlLauncher = (uri) async {
        opened.add(uri);
        if (launchError case final e?) throw e;
        return launchResult;
      };
    });

    tearDown(() {
      externalUrlLauncher = (uri) async =>
          throw StateError('no browser in tests');
    });

    Future<void> tapKey(WidgetTester tester, String key) async {
      final finder = find.byKey(Key(key));
      await tester.ensureVisible(finder);
      await tester.pumpAndSettle();
      await tester.tap(finder);
      await tester.pumpAndSettle();
    }

    testWidgets('signed in: privacy policy row opens the policy URL',
        (tester) async {
      await setUpWorld(tester);
      expect(find.text('개인정보처리방침'), findsOneWidget);
      await tapKey(tester, 'privacyPolicyLink');
      expect(opened, [Uri.parse(kPrivacyPolicyUrl!)]);
      expect(find.byKey(const Key('externalLinkFailedDialog')), findsNothing);
      expect(deletionAuth.reauthCalls, 0);
    });

    testWidgets('signed out: privacy policy row is still offered',
        (tester) async {
      await setUpWorld(tester);
      await account.signOut();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('privacyPolicyLink')), findsOneWidget);
      await tapKey(tester, 'privacyPolicyLink');
      expect(opened, [Uri.parse(kPrivacyPolicyUrl!)]);
    });

    testWidgets(
        'deletion dialog: external request link opens the web page only',
        (tester) async {
      await setUpWorld(tester);
      await tapKey(tester, 'accountDeleteButton');
      expect(find.text('앱 밖에서 계정 삭제 요청'), findsOneWidget);
      expect(find.textContaining('https://'), findsNothing);

      await tapKey(tester, 'accountDeletionExternalLink');
      expect(opened, [Uri.parse(kAccountDeletionRequestUrl!)]);
      // The dialog stays open and nothing was deleted or started.
      expect(find.text('계정과 클라우드 백업을 삭제할까요?'), findsOneWidget);
      expect(deletionAuth.reauthCalls, 0);
      expect(deletionAuth.deleteCalls, 0);
      expect(eraser.calls, 0);
      expect(store.pending, isNull);
      expect(deletion.busy, isFalse);
      expect(account.phase, AccountPhase.signedIn);

      // The in-app delete button still works afterwards.
      await tapKey(tester, 'accountDeleteConfirm');
      expect(deletionAuth.reauthCalls, 1);
      expect(deletionAuth.deleteCalls, 1);
      expect(account.phase, AccountPhase.signedOut);
      expect(opened, hasLength(1));
    });

    testWidgets('launcher returns false: notice, no crash', (tester) async {
      await setUpWorld(tester);
      launchResult = false;
      await tapKey(tester, 'privacyPolicyLink');
      expect(find.byKey(const Key('externalLinkFailedDialog')), findsOneWidget);
      expect(find.textContaining('링크를 열지 못했어요'), findsOneWidget);
      await tester.tap(find.text('확인'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('externalLinkFailedDialog')), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('launcher throws: notice, no crash, deletion untouched',
        (tester) async {
      await setUpWorld(tester);
      launchError = Exception('no activity');
      await tapKey(tester, 'accountDeleteButton');
      await tapKey(tester, 'accountDeletionExternalLink');
      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('externalLinkFailedDialog')), findsOneWidget);
      expect(deletionAuth.reauthCalls, 0);
      expect(eraser.calls, 0);
    });

    testWidgets('only http/https links reach the launcher', (tester) async {
      late BuildContext ctx;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (c) {
              ctx = c;
              return const SizedBox();
            },
          ),
        ),
      );
      for (final bad in [
        'mailto:utanote.karaoke@gmail.com',
        'javascript:alert(1)',
        'file:///etc/hosts',
        'intent://x',
        '/relative/path',
        'https://',
      ]) {
        final f = openExternalUrl(ctx, bad);
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('externalLinkFailedDialog')), findsOneWidget,
            reason: bad);
        await tester.tap(find.text('확인'));
        await tester.pumpAndSettle();
        expect(await f, isFalse, reason: bad);
      }
      expect(opened, isEmpty);
      expect(isAllowedExternalUrl(Uri.parse('http://example.com/')), isTrue);
      expect(isAllowedExternalUrl(Uri.parse(kPrivacyPolicyUrl!)), isTrue);
      expect(
        isAllowedExternalUrl(Uri.parse(kAccountDeletionRequestUrl!)),
        isTrue,
      );
    });
  });

  // --- Phase B-5.1: same Google account, new uid ---------------------------

  testWidgets('same email, new uid: release section and confirmation',
      (tester) async {
    final bound = _StaleBinding(uid: 'uid-old', email: 'Alice@Example.com');
    final auth = FakeAuth(_alice);
    final account = AccountController(gateway: auth, boundAccount: bound);
    final deletion = AccountDeletionController(
      account: account,
      auth: FakeDeletionAuth(_alice),
      store: _MemStore(),
      eraser: FakeCloudEraser(FakeCloudBackend()),
    );
    account.deletion = deletion;
    await account.start();
    auth.users.add(_alice);
    await tester.pumpAndSettle();
    expect(account.linkStatus, AccountLinkStatus.previousAccountSameEmail);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(child: AccountSheet(account: account)),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('previousBindingSection')), findsOneWidget);
    expect(find.byKey(const Key('accountDeleteButton')), findsNothing);
    expect(find.byKey(const Key('signOutButton')), findsOneWidget);

    // 취소: nothing changes.
    await tester.tap(find.byKey(const Key('releasePreviousBindingButton')));
    await tester.pumpAndSettle();
    expect(
      find.text('이 기기는 이전 UtaNote 클라우드 계정에 연결되어 있어요.'),
      findsOneWidget,
    );
    expect(find.textContaining('새 클라우드 백업을 다시 설정하시겠어요?'), findsOneWidget);
    await tester.tap(find.byKey(const Key('releasePreviousBindingCancel')));
    await tester.pumpAndSettle();
    expect(bound.releases, 0);
    expect(bound.uid, 'uid-old');

    // Confirm: released locally, device now unbound.
    await tester.tap(find.byKey(const Key('releasePreviousBindingButton')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('releasePreviousBindingConfirm')));
    await tester.pumpAndSettle();
    expect(bound.releases, 1);
    expect(bound.uid, isNull);
    expect(account.linkStatus, AccountLinkStatus.unlinked);
    expect(find.byKey(const Key('previousBindingSection')), findsNothing);
  });

  testWidgets('different email: signed out with the blocked notice',
      (tester) async {
    final bound = _StaleBinding(uid: 'uid-old', email: 'someone@else.com');
    final auth = FakeAuth(_alice);
    final account = AccountController(gateway: auth, boundAccount: bound);
    await account.start();
    auth.users.add(_alice);
    await tester.pumpAndSettle();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(child: AccountSheet(account: account)),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(account.phase, AccountPhase.signedOut);
    expect(find.textContaining('다른 Google 계정의 백업에 연결되어 있어요'), findsOneWidget);
    expect(find.byKey(const Key('previousBindingSection')), findsNothing);
    expect(bound.releases, 0);
  });

  // --- Account sheet layout (the real bottom sheet, real app theme) -------

  /// Opens the bound-account sheet the way the app does
  /// ([showAccountSheet]) on a [width]x[height] screen with the given
  /// safe-area insets and text scale. Connected with "지금 동기화", so the
  /// sheet has every row a bound account shows.
  Future<AccountController> openBoundAccountSheet(
    WidgetTester tester, {
    required double width,
    required double height,
    double top = 0,
    double bottom = 0,
    double textScale = 1,
  }) async {
    tester.view.physicalSize = Size(width, height);
    tester.view.devicePixelRatio = 1;
    tester.view.padding = FakeViewPadding(top: top, bottom: bottom);
    addTearDown(tester.view.reset);

    final auth = FakeAuth(_alice);
    final account = AccountController(
      gateway: auth,
      boundAccount: _CurrentBinding(uid: _alice.uid),
    );
    account.cloudSync = CloudSyncController(
      engine: InitialSyncEngine(
        store: _UnusedStore(),
        backend: FakeCloudBackend(),
      ),
      manual: ManualSyncEngine(
        store: _UnusedStore(),
        backend: FakeCloudBackend(),
      ),
      account: account,
    );
    account.deletion = AccountDeletionController(
      account: account,
      auth: FakeDeletionAuth(_alice),
      store: _MemStore(),
      eraser: FakeCloudEraser(FakeCloudBackend()),
    );
    await account.start();
    auth.users.add(_alice);
    await tester.pumpAndSettle();
    expect(account.cloudSync!.phase, CloudSyncPhase.connected);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(textScale),
          ),
          child: child!,
        ),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                key: const Key('openAccountSheet'),
                onPressed: () => showAccountSheet(context, account),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('openAccountSheet')));
    await tester.pumpAndSettle();
    expect(find.byType(AccountSheet), findsOneWidget);
    return account;
  }

  ScrollPosition sheetScroll(WidgetTester tester) => tester
      .state<ScrollableState>(
        find.descendant(
          of: find.byType(AccountSheet),
          matching: find.byType(Scrollable),
        ),
      )
      .position;

  // Common iPhone screens (logical points, safe-area insets).
  const iPhones = <String, (double, double, double, double)>{
    'iPhone SE (2nd/3rd) 375x667': (375, 667, 20, 0),
    'iPhone 13 mini 375x812': (375, 812, 50, 34),
    'iPhone 15 390x844': (390, 844, 47, 34),
    'iPhone 15 Pro Max 430x932': (430, 932, 59, 34),
  };

  for (final MapEntry(key: name, value: (w, h, top, bottom))
      in iPhones.entries) {
    testWidgets('$name: whole sheet visible without scrolling', (tester) async {
      await openBoundAccountSheet(
        tester,
        width: w,
        height: h,
        top: top,
        bottom: bottom,
      );
      expect(tester.takeException(), isNull);
      // Nothing to scroll: the sheet is as tall as its content.
      expect(sheetScroll(tester).maxScrollExtent, 0);
      // The red deletion entry is on screen, above the home indicator.
      final delete = tester.getRect(
        find.byKey(const Key('accountDeleteButton')),
      );
      expect(delete.top, greaterThanOrEqualTo(top));
      expect(delete.bottom, lessThanOrEqualTo(h - bottom));
      // The sheet stays below the status bar.
      expect(
        tester.getRect(find.byType(AccountSheet)).top,
        greaterThanOrEqualTo(top),
      );
      // 로그아웃 and 클라우드 연결 해제 share one row, side by side.
      final signOut = tester.getRect(find.byKey(const Key('signOutButton')));
      final release = tester.getRect(
        find.byKey(const Key('releaseCloudBindingButton')),
      );
      expect(signOut.center.dy, release.center.dy);
      expect(signOut.right, lessThanOrEqualTo(release.left));
      expect(find.text('클라우드 연결 해제'), findsOneWidget);
      expect(find.text('로그아웃해도 이 기기의 노래와 폴더는 삭제되지 않습니다.'),
          findsOneWidget);
      expect(find.textContaining('다른 Google 계정을 쓰려면'), findsNothing);
      expect(find.byKey(const Key('privacyPolicyLink')), findsOneWidget);
    });
  }

  testWidgets('320pt wide screen: no overflow, labels kept on one line',
      (tester) async {
    await openBoundAccountSheet(tester, width: 320, height: 568, top: 20);
    expect(tester.takeException(), isNull);
    expect(find.text('로그아웃'), findsOneWidget);
    expect(find.text('클라우드 연결 해제'), findsOneWidget);
    expect(
      tester.getRect(find.byKey(const Key('accountDeleteButton'))).bottom,
      lessThanOrEqualTo(568),
    );
  });

  for (final (w, h, scale) in [(390.0, 844.0, 1.3), (320.0, 568.0, 2.0)]) {
    testWidgets('large text x$scale on ${w.toInt()}x${h.toInt()}: no overflow; '
        'scrolls to the deletion entry', (tester) async {
      await openBoundAccountSheet(
        tester,
        width: w,
        height: h,
        top: 20,
        textScale: scale,
      );
      expect(tester.takeException(), isNull);
      final signOut = tester.getRect(find.byKey(const Key('signOutButton')));
      final release = tester.getRect(
        find.byKey(const Key('releaseCloudBindingButton')),
      );
      expect(signOut.right, lessThanOrEqualTo(release.left));
      expect(release.right, lessThanOrEqualTo(w));
      await tester.ensureVisible(find.byKey(const Key('accountDeleteButton')));
      await tester.pumpAndSettle();
      expect(
        tester.getRect(find.byKey(const Key('accountDeleteButton'))).bottom,
        lessThanOrEqualTo(h),
      );
    });
  }

  testWidgets('row actions keep their behavior: 로그아웃, 연결 해제, 삭제',
      (tester) async {
    final account = await openBoundAccountSheet(
      tester,
      width: 375,
      height: 667,
      top: 20,
    );
    // 클라우드 연결 해제 → its confirmation dialog.
    await tester.tap(find.byKey(const Key('releaseCloudBindingButton')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('releaseCloudBindingDialog')), findsOneWidget);
    await tester.tap(find.byKey(const Key('releaseCloudBindingCancel')));
    await tester.pumpAndSettle();
    expect(account.phase, AccountPhase.signedIn);
    // 계정 및 클라우드 데이터 삭제 → its confirmation dialog.
    await tester.tap(find.byKey(const Key('accountDeleteButton')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('accountDeleteDialog')), findsOneWidget);
    await tester.tap(find.byKey(const Key('accountDeleteCancel')));
    await tester.pumpAndSettle();
    expect(account.phase, AccountPhase.signedIn);
    // 로그아웃 → signed out.
    await tester.tap(find.byKey(const Key('signOutButton')));
    await tester.pumpAndSettle();
    expect(account.phase, AccountPhase.signedOut);
  });

  // --- "이 기기의 클라우드 연결 해제" (current account) ---------------------

  Future<(AccountController, _CurrentBinding)> boundSheet(
    WidgetTester tester,
  ) async {
    final bound = _CurrentBinding(uid: _alice.uid);
    final auth = FakeAuth(_alice);
    final account = AccountController(gateway: auth, boundAccount: bound);
    account.cloudSync = CloudSyncController(
      engine: InitialSyncEngine(
        store: _UnusedStore(),
        backend: FakeCloudBackend(),
      ),
      account: account,
    );
    account.deletion = AccountDeletionController(
      account: account,
      auth: FakeDeletionAuth(_alice),
      store: _MemStore(),
      eraser: FakeCloudEraser(FakeCloudBackend()),
    );
    await account.start();
    auth.users.add(_alice);
    await tester.pumpAndSettle();
    expect(account.linkStatus, AccountLinkStatus.sameAccount);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(child: AccountSheet(account: account)),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return (account, bound);
  }

  testWidgets('bound account: sign-out, release and deletion are separate',
      (tester) async {
    final (account, bound) = await boundSheet(tester);
    expect(find.byKey(const Key('signOutButton')), findsOneWidget);
    expect(find.byKey(const Key('releaseCloudBindingButton')), findsOneWidget);
    expect(find.text('클라우드 연결 해제'), findsOneWidget);
    // The long explanation moved into the confirmation dialog.
    expect(find.textContaining('다른 Google 계정을 쓰려면'), findsNothing);
    expect(find.byKey(const Key('accountDeleteButton')), findsOneWidget);

    // 취소: nothing changes.
    await tester.tap(find.byKey(const Key('releaseCloudBindingButton')));
    await tester.pumpAndSettle();
    expect(find.text('이 기기의 클라우드 연결을 해제할까요?'), findsOneWidget);
    expect(find.textContaining('노래와 폴더는 그대로 유지돼요'), findsOneWidget);
    expect(find.textContaining('alice@example.com의 클라우드 백업은 삭제되지 않아요'),
        findsOneWidget);
    expect(find.textContaining('자동으로 올라가지 않아요'), findsOneWidget);
    await tester.tap(find.byKey(const Key('releaseCloudBindingCancel')));
    await tester.pumpAndSettle();
    expect(bound.releases, 0);
    expect(bound.uid, _alice.uid);
    expect(account.phase, AccountPhase.signedIn);

    // Confirm: released locally and signed out, with the explanation.
    await tester.tap(find.byKey(const Key('releaseCloudBindingButton')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('releaseCloudBindingConfirm')));
    await tester.pumpAndSettle();
    expect(bound.releases, 1);
    expect(bound.uid, isNull);
    expect(account.phase, AccountPhase.signedOut);
    expect(find.byKey(const Key('cloudBindingReleasedNotice')), findsOneWidget);
    expect(find.byKey(const Key('releaseCloudBindingButton')), findsNothing);
  });

  testWidgets('unbound device: no release entry', (tester) async {
    await setUpWorld(tester);
    expect(find.byKey(const Key('releaseCloudBindingButton')), findsNothing);
  });

  for (final width in [320.0, 375.0, 390.0]) {
    testWidgets('delete dialog buttons fit on one line at width $width',
        (tester) async {
      tester.view.physicalSize = Size(width * 3, 700 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await setUpWorld(tester);
      await tester.ensureVisible(find.byKey(const Key('accountDeleteButton')));
      await tester.tap(find.byKey(const Key('accountDeleteButton')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull); // no RenderFlex overflow

      final confirm = find.byKey(const Key('accountDeleteConfirm'));
      final cancel = find.byKey(const Key('accountDeleteCancel'));
      expect(
        tester.getSize(confirm).width,
        greaterThan(tester.getSize(cancel).width),
      );
      // The label is laid out at full size, on one line, inside the button.
      final label = find.descendant(
        of: confirm,
        matching: find.text('계정 및 백업 삭제'),
      );
      final labelBox = tester.getRect(label);
      final buttonBox = tester.getRect(confirm);
      expect(buttonBox.contains(labelBox.topLeft), isTrue);
      expect(buttonBox.contains(labelBox.bottomRight), isTrue);
      final fitted = tester.widget<FittedBox>(
        find.descendant(of: confirm, matching: find.byType(FittedBox)),
      );
      expect(fitted.fit, BoxFit.scaleDown);
      final rendered = tester.renderObject<RenderParagraph>(label);
      expect(rendered.size.height, lessThan(rendered.text.style!.fontSize! * 2));
      // Full size (not scaled down) on today's phone widths; on 320 the
      // test font (every glyph 1em wide) is wider than real Korean text, so
      // only the "fits inside" checks above apply there.
      if (width >= 375) {
        expect(labelBox.width, closeTo(rendered.size.width, 0.5));
      }

      await tester.tap(cancel);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('accountDeleteDialog')), findsNothing);
    });
  }
}

class _UnusedStore implements LocalSyncStore {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _CurrentBinding implements BoundAccountSource, CloudBindingRelease {
  String? uid;
  int releases = 0;

  _CurrentBinding({this.uid});

  @override
  Future<String?> readBoundAccountUid() async => uid;

  @override
  Future<void> releaseCloudBinding({required String expectedBoundUid}) async {
    if (uid != expectedBoundUid) throw StateError('binding changed');
    releases++;
    uid = null;
  }
}

class _StaleBinding
    implements
        BoundAccountSource,
        BoundAccountEmailSource,
        PreviousBindingRelease {
  String? uid;
  String? email;
  int releases = 0;

  _StaleBinding({this.uid, this.email});

  @override
  Future<String?> readBoundAccountUid() async => uid;

  @override
  Future<String?> readBoundAccountEmailHint() async => email;

  @override
  Future<void> releasePreviousBinding({required String expectedBoundUid}) async {
    if (uid != expectedBoundUid) throw StateError('binding changed');
    releases++;
    uid = null;
    email = null;
  }
}
