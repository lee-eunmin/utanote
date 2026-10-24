import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:utanote/account/account_controller.dart';
import 'package:utanote/account/account_deletion.dart';
import 'package:utanote/account/auth_gateway.dart';
import 'package:utanote/config/account_links.dart';
import 'package:utanote/sync/account_data_deletion.dart';
import 'package:utanote/sync/cloud_sync_backend.dart';
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
