import 'dart:async';

import 'package:flutter/foundation.dart';

import '../sync/cloud_sync_controller.dart';
import 'account_deletion.dart';
import 'auth_gateway.dart';

enum AccountPhase {
  /// Sign-in backend is starting up.
  initializing,

  /// Sign-in is not available on this build/device (e.g. Firebase is not
  /// configured, or failed to start). The rest of the app works normally.
  unavailable,

  signedOut,
  signingIn,
  signedIn,
}

/// Sign-in state for the UI. Sign-in only: this class never reads or
/// writes songs/folders, never marks anything clean or dirty, and never
/// writes `sync_meta.account_uid` (binding happens in the sync layer after
/// a successful first upload/restore).
class AccountController extends ChangeNotifier {
  final AuthGateway _gateway;
  final BoundAccountSource _boundAccount;

  AccountController({
    required this._gateway,
    required this._boundAccount,
  });

  /// First cloud connection for the signed-in account (Android only;
  /// attached once at startup). Null → no cloud backup entry in the UI.
  CloudSyncController? cloudSync;

  /// "계정 및 클라우드 데이터 삭제" (Phase B-5, Android only; attached once
  /// at startup). Null → no deletion entry in the UI.
  AccountDeletionController? deletion;

  AccountPhase _phase = AccountPhase.initializing;
  AccountUser? _user;
  AccountLinkStatus? _linkStatus;
  String? _message;
  StreamSubscription<AccountUser?>? _sub;
  Future<void>? _starting;

  /// Bumped on every state-changing event so an older async step that
  /// finishes late can't overwrite a newer state.
  int _generation = 0;

  AccountPhase get phase => _phase;
  AccountUser? get user => _user;
  AccountLinkStatus? get linkStatus => _linkStatus;

  /// Last user-facing notice (failure, blocked account), if any.
  String? get message => _message;

  /// True only when signed in with an account that may sync with this
  /// device's data (local data unbound, or bound to this same account).
  bool get canSync =>
      _phase == AccountPhase.signedIn &&
      (_linkStatus == AccountLinkStatus.unlinked ||
          _linkStatus == AccountLinkStatus.sameAccount);

  /// Starts the backend once. Never throws.
  Future<void> start() => _starting ??= _start();

  Future<void> _start() async {
    bool ok;
    try {
      ok = await _gateway.initialize();
    } catch (e) {
      debugPrint('[account] initialize failed: $e');
      ok = false;
    }
    if (!ok) {
      _set(AccountPhase.unavailable);
      return;
    }
    _set(AccountPhase.signedOut);
    try {
      _sub = _gateway.userChanges().listen(
        (user) {
          // While signIn() is running it applies its own result (so it
          // completes with the final state); stream events in that window —
          // the initial "no user", or the new user echoed by Firebase —
          // must not race it.
          if (_phase == AccountPhase.signingIn) return;
          _applyUser(user, ++_generation);
        },
        onError: (Object e) => debugPrint('[account] user stream error: $e'),
      );
    } catch (e) {
      debugPrint('[account] user stream failed: $e');
      _set(AccountPhase.unavailable);
    }
  }

  Future<void> signIn() async {
    if (_phase != AccountPhase.signedOut) return;
    final gen = ++_generation;
    _message = null;
    _set(AccountPhase.signingIn);
    try {
      final user = await _gateway.signInWithGoogle();
      await _applyUser(user, gen);
    } on AccountSignInCancelled {
      if (gen == _generation) _set(AccountPhase.signedOut);
    } on AccountSignInFailure catch (e) {
      debugPrint('[account] sign-in failed: $e');
      if (gen == _generation) {
        _message = e.message;
        _set(AccountPhase.signedOut);
      }
    } catch (e) {
      debugPrint('[account] sign-in error: $e');
      if (gen == _generation) {
        _message = '로그인하지 못했어요. 잠시 후 다시 시도해 주세요.';
        _set(AccountPhase.signedOut);
      }
    }
  }

  /// The account this device's data is bound to (`sync_meta.account_uid`),
  /// or null if unbound. Read-only. If it can't be read, returns a
  /// non-null placeholder, so callers treat the device as bound and never
  /// offer to connect it.
  Future<String?> readBoundAccountUid() async {
    try {
      final uid = await _boundAccount.readBoundAccountUid();
      return (uid == null || uid.isEmpty) ? null : uid;
    } catch (e) {
      debugPrint('[account] reading bound account failed: $e');
      return '\u0000unknown';
    }
  }

  /// Re-reads the device's account binding for the signed-in user, e.g.
  /// after the first cloud connection wrote `account_uid`. Read-only.
  Future<void> refreshLink() async {
    final user = _user;
    if (_phase != AccountPhase.signedIn || user == null) return;
    await _applyUser(user, ++_generation);
  }

  /// Ends the cloud session only. Local songs/folders and
  /// `sync_meta.account_uid` are left exactly as they are.
  Future<void> signOut() async {
    final gen = ++_generation;
    try {
      await _gateway.signOut();
    } catch (e) {
      debugPrint('[account] sign-out error: $e');
    }
    if (gen == _generation) {
      _user = null;
      _linkStatus = null;
      _set(AccountPhase.signedOut);
    }
  }

  Future<void> _applyUser(AccountUser? user, int gen) async {
    if (user == null) {
      if (gen != _generation) return;
      _user = null;
      _linkStatus = null;
      _set(AccountPhase.signedOut);
      return;
    }

    String? boundUid;
    try {
      boundUid = await _boundAccount.readBoundAccountUid();
    } catch (e) {
      // Can't tell which account the data belongs to: treat as a mismatch
      // so nothing can sync, rather than guess.
      debugPrint('[account] reading bound account failed: $e');
      boundUid = '\u0000unknown';
    }
    if (gen != _generation) return;

    var link = evaluateAccountLink(boundUid: boundUid, signedInUid: user.uid);
    if (link == AccountLinkStatus.otherAccount &&
        await _boundToSameEmail(user)) {
      if (gen != _generation) return;
      // The same Google account with a new uid (deleted and re-created).
      // Stay signed in without syncing; the user may explicitly release
      // the old binding (Phase B-5.1). Nothing changes automatically.
      link = AccountLinkStatus.previousAccountSameEmail;
    }
    if (gen != _generation) return;
    if (link == AccountLinkStatus.otherAccount) {
      // Policy: a different account may not be used on a device whose data
      // belongs to another account. End the session; local data and the
      // binding are untouched. State is set first so the sign-out's own
      // "no user" event can't race it.
      _user = null;
      _linkStatus = null;
      _message = '이 기기는 다른 Google 계정의 백업에 연결되어 있어요. '
          '기존 계정으로 로그인해 주세요.';
      _set(AccountPhase.signedOut);
      try {
        await _gateway.signOut();
      } catch (e) {
        debugPrint('[account] sign-out after mismatch failed: $e');
      }
      return;
    }

    _user = user;
    _linkStatus = link;
    _message = null;
    _set(AccountPhase.signedIn);
  }

  /// Whether the binding was recorded with the signed-in user's email
  /// (case-insensitive). False when either email is unknown or unreadable.
  Future<bool> _boundToSameEmail(AccountUser user) async {
    final source = _boundAccount;
    if (source is! BoundAccountEmailSource) return false;
    try {
      final hint =
          await (source as BoundAccountEmailSource).readBoundAccountEmailHint();
      return sameAccountEmail(hint, user.email);
    } catch (e) {
      debugPrint('[account] reading bound email failed: $e');
      return false;
    }
  }

  /// "이 기기의 이전 클라우드 연결 해제" (Phase B-5.1): only after the user
  /// confirmed, only while signed in as the same Google email with a new
  /// uid. Local only: removes the old binding/sync bookkeeping and marks
  /// everything "needs upload"; songs and folders stay; nothing is
  /// uploaded or merged. Afterwards the device is unbound, so the normal
  /// "클라우드 백업 설정" (first connection) can be started by the user.
  /// Returns false (changing nothing) if it doesn't apply or failed.
  Future<bool> releasePreviousCloudBinding() async {
    final user = _user;
    final release = _boundAccount;
    if (_phase != AccountPhase.signedIn ||
        user == null ||
        _linkStatus != AccountLinkStatus.previousAccountSameEmail ||
        release is! PreviousBindingRelease) {
      return false;
    }
    final bound = await readBoundAccountUid();
    if (bound == null || bound == user.uid || bound == ' unknown') {
      return false;
    }
    try {
      await (release as PreviousBindingRelease)
          .releasePreviousBinding(expectedBoundUid: bound);
    } catch (e) {
      debugPrint('[account] releasing previous binding failed: $e');
      _message = '이전 클라우드 연결을 해제하지 못했어요. 이 기기의 노래와 폴더는 그대로예요.';
      notifyListeners();
      return false;
    }
    _message = null;
    cloudSync?.onBindingReleased();
    await deletion?.reloadPending();
    await refreshLink();
    return true;
  }

  void _set(AccountPhase phase) {
    _phase = phase;
    notifyListeners();
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}
