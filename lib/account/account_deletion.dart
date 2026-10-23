/// "계정 및 클라우드 데이터 삭제" (Phase B-5).
///
/// Order of a deletion (each step only after the previous one succeeded):
/// 1. Stop every sync and wait for a running one to finish.
/// 2. Re-authenticate with Google. The re-authenticated account must be the
///    signed-in one (and the one this device is bound to, if bound).
///    Cancel/failure/mismatch → nothing was deleted; sync resumes.
/// 3. Record the deletion locally (`sync_meta`), so an interrupted run is
///    remembered across restarts and sync stays off until it finishes.
/// 4. Create `accountDeletionBlocks/{uid}` and confirm it exists (Phase
///    B-5.1). From then on the security rules refuse every create/update
///    under `users/{uid}`, so a stale device whose ID token is still valid
///    can't re-create anything. If the block can't be confirmed, no user
///    document is deleted.
/// 5. Hard-delete every cloud document of that uid, in batches. Idempotent:
///    a retry deletes whatever is left.
/// 6. Delete the Firebase Auth user.
/// 7. One local transaction: remove the binding/sync bookkeeping, mark all
///    rows "needs upload". Local songs/folders are never deleted.
/// 8. End the Google session; signed out. The block stays.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../sync/account_data_deletion.dart';
import '../sync/cloud_sync_controller.dart';
import 'account_controller.dart';
import 'auth_gateway.dart';

/// The re-authenticated Google account is not the signed-in one.
class AccountReauthMismatch implements Exception {
  const AccountReauthMismatch();

  @override
  String toString() => 'AccountReauthMismatch';
}

enum AccountDeletionAuthErrorKind { requiresRecentLogin, network, other }

/// Deleting the Firebase Auth user failed. [detail] is for logs only.
class AccountDeletionAuthException implements Exception {
  final AccountDeletionAuthErrorKind kind;
  final String detail;

  const AccountDeletionAuthException(this.kind, this.detail);

  @override
  String toString() => 'AccountDeletionAuthException(${kind.name}: $detail)';
}

/// The Firebase/Google side of account deletion. Implemented by
/// `FirebaseAuthGateway`; tests use a fake.
abstract class AccountDeletionAuth {
  /// The uid Firebase currently has signed in, or null.
  String? get currentUid;

  /// Shows the Google account picker again and re-authenticates the
  /// current Firebase user with it. Throws [AccountSignInCancelled],
  /// [AccountSignInFailure] or [AccountReauthMismatch].
  Future<AccountUser> reauthenticate();

  /// Deletes the current Firebase Auth user. Throws
  /// [AccountDeletionAuthException].
  Future<void> deleteCurrentUser();

  /// Ends (and if possible revokes) the Google session. Never throws.
  Future<void> endGoogleSession();
}

enum AccountDeletionStatus {
  idle,
  reauthenticating,

  /// Creating the cloud deletion block.
  blockingCloud,
  deletingCloud,
  deletingAccount,
  finishing,

  /// The last attempt stopped; see [AccountDeletionController.message].
  failed,

  /// Finished in this app run: account and cloud data deleted.
  completed,
}

class AccountDeletionController extends ChangeNotifier {
  final AccountController _account;
  final AccountDeletionAuth _auth;
  final AccountDeletionStore _store;
  final CloudAccountDataEraser _eraser;

  /// Called once after a successful deletion (e.g. to snooze the backup
  /// prompt). Errors are ignored.
  final Future<void> Function()? onCompleted;

  AccountDeletionController({
    required this._account,
    required this._auth,
    required this._store,
    required this._eraser,
    this.onCompleted,
  });

  AccountDeletionStatus _status = AccountDeletionStatus.idle;
  String? _message;
  PendingAccountDeletion? _pending;
  int _deletedThisRun = 0;
  bool _completedThisLaunch = false;
  Future<void>? _loading;

  AccountDeletionStatus get status => _status;

  /// User-facing notice after a failed attempt.
  String? get message => _message;

  /// A deletion started earlier (this run or before a restart) that has
  /// not finished. While set, sync stays off.
  PendingAccountDeletion? get pending => _pending;

  /// Cloud documents deleted during the current attempt.
  int get deletedThisRun => _deletedThisRun;

  /// An account was deleted during this app run.
  bool get completedThisLaunch => _completedThisLaunch;

  bool get busy => switch (_status) {
    AccountDeletionStatus.reauthenticating ||
    AccountDeletionStatus.blockingCloud ||
    AccountDeletionStatus.deletingCloud ||
    AccountDeletionStatus.deletingAccount ||
    AccountDeletionStatus.finishing => true,
    _ => false,
  };

  CloudSyncController? get _cloud => _account.cloudSync;

  /// Reads an unfinished deletion left by an earlier run (once). If one
  /// exists, sync is suspended; if only the local cleanup was left (the
  /// Auth user is already gone), it is finished now. Never throws.
  Future<void> load() => _loading ??= _load();

  Future<void> _load() async {
    PendingAccountDeletion? pending;
    try {
      pending = await _store.readPendingAccountDeletion();
    } catch (e) {
      debugPrint('[account-deletion] reading state failed: $e');
      return;
    }
    if (pending == null) return;
    _pending = pending;
    notifyListeners();
    await _cloud?.suspendForAccountDeletion();
    if (pending.stage == AccountDeletionStage.authDeleted) {
      await _finishLocally(pending.uid);
    }
  }

  /// Re-reads the local deletion record (e.g. after the old binding was
  /// released, which also clears a stale marker) and resumes sync if no
  /// deletion is pending any more.
  Future<void> reloadPending() async {
    if (busy) return;
    PendingAccountDeletion? pending;
    try {
      pending = await _store.readPendingAccountDeletion();
    } catch (e) {
      debugPrint('[account-deletion] reading state failed: $e');
      return;
    }
    final had = _pending != null;
    _pending = pending;
    if (pending == null && had) {
      _message = null;
      _status = AccountDeletionStatus.idle;
      _cloud?.resumeAfterAccountDeletion();
    }
    notifyListeners();
  }

  /// Runs (or resumes) the deletion for the signed-in account. The caller
  /// must have shown the confirmation already. Never throws.
  Future<void> deleteAccount() async {
    if (busy) return;
    await load();
    final user = _account.user;
    if (_account.phase != AccountPhase.signedIn || user == null) return;
    final uid = user.uid;
    final pending = _pending;
    if (pending != null && pending.uid != uid) {
      _fail('다른 계정의 삭제가 진행 중이에요. 그 계정으로 로그인한 뒤 다시 시도해 주세요.');
      return;
    }

    _message = null;
    _deletedThisRun = 0;
    _setStatus(AccountDeletionStatus.reauthenticating);

    // 1. No sync from here on (waits for a running one).
    await _cloud?.suspendForAccountDeletion();

    // 2. Re-authenticate: same account only.
    try {
      final reauth = await _auth.reauthenticate();
      if (reauth.uid != uid || _auth.currentUid != uid) {
        throw const AccountReauthMismatch();
      }
      final bound = await _account.readBoundAccountUid();
      if (bound != null && bound != uid) {
        throw const AccountReauthMismatch();
      }
    } on AccountSignInCancelled {
      _abortBeforeDeleting(null);
      return;
    } on AccountReauthMismatch {
      _abortBeforeDeleting('선택한 Google 계정이 지금 로그인한 계정과 달라요. 아무것도 삭제하지 않았어요.');
      return;
    } on AccountSignInFailure catch (e) {
      debugPrint('[account-deletion] reauth failed: $e');
      _abortBeforeDeleting('${e.message} 아무것도 삭제하지 않았어요.');
      return;
    } catch (e) {
      debugPrint('[account-deletion] reauth error: $e');
      _abortBeforeDeleting('본인 확인을 하지 못했어요. 아무것도 삭제하지 않았어요.');
      return;
    }

    // 3. Remember the deletion before touching the cloud.
    try {
      await _store.markAccountDeletionStarted(uid);
      _pending =
          await _store.readPendingAccountDeletion() ??
          PendingAccountDeletion(uid: uid, stage: AccountDeletionStage.blocking);
    } catch (e) {
      debugPrint('[account-deletion] could not record start: $e');
      _abortBeforeDeleting('삭제를 시작하지 못했어요. 아무것도 삭제하지 않았어요.');
      return;
    }

    // 4. Block the uid in the cloud first; no user document is deleted
    // unless the block is confirmed.
    _setStatus(AccountDeletionStatus.blockingCloud);
    try {
      await _eraser.ensureDeletionBlock(uid);
    } catch (e) {
      debugPrint('[account-deletion] deletion block failed: $e');
      await _afterBlockFailure(uid);
      return;
    }
    await _quiet(
      () => _store.recordAccountDeletionProgress(
        uid,
        stage: AccountDeletionStage.cloudDeleting,
      ),
    );
    await _refreshPending();

    // 4. Cloud data. Always run (idempotent): on a retry this also removes
    // anything another device uploaded in the meantime.
    _setStatus(AccountDeletionStatus.deletingCloud);
    final before = _pending?.deletedDocs ?? 0;
    try {
      await _eraser.deleteAllUserData(
        uid,
        onBatchCommitted: (n) {
          _deletedThisRun = n;
          notifyListeners();
          unawaited(
            _quiet(
              () => _store.recordAccountDeletionProgress(
                uid,
                deletedDocs: before + n,
              ),
            ),
          );
        },
      );
    } catch (e) {
      debugPrint('[account-deletion] cloud delete failed: $e');
      await _refreshPending();
      _fail(
        _deletedThisRun > 0 || before > 0
            ? '클라우드 백업 삭제가 중간에 멈췄어요. 다시 시도하면 남은 백업을 이어서 '
                  '삭제해요. 이 기기의 노래와 폴더는 그대로예요.'
            : '클라우드 백업을 삭제하지 못했어요. 네트워크 연결을 확인한 뒤 다시 '
                  '시도해 주세요. 이 기기의 노래와 폴더는 그대로예요.',
      );
      return;
    }
    await _quiet(
      () => _store.recordAccountDeletionProgress(
        uid,
        stage: AccountDeletionStage.cloudDeleted,
      ),
    );
    await _refreshPending();

    // 5. The Firebase Auth user, only after the cloud data is gone.
    _setStatus(AccountDeletionStatus.deletingAccount);
    try {
      if (_auth.currentUid != uid) {
        throw const AccountDeletionAuthException(
          AccountDeletionAuthErrorKind.other,
          'signed-in user changed',
        );
      }
      await _auth.deleteCurrentUser();
    } catch (e) {
      debugPrint('[account-deletion] auth delete failed: $e');
      final again =
          e is AccountDeletionAuthException &&
          e.kind == AccountDeletionAuthErrorKind.requiresRecentLogin;
      _fail(
        '클라우드 백업은 삭제됐지만 계정을 삭제하지 못했어요. '
        '${again ? '보안을 위해 다시 본인 확인이 필요해요. ' : ''}'
        '다시 시도해 주세요. 이 기기의 노래와 폴더는 그대로예요.',
      );
      return;
    }
    await _quiet(
      () => _store.recordAccountDeletionProgress(
        uid,
        stage: AccountDeletionStage.authDeleted,
      ),
    );

    // 6–7. Local cleanup and sign-out.
    await _finishLocally(uid);
  }

  Future<void> _finishLocally(String uid) async {
    _setStatus(AccountDeletionStatus.finishing);
    Object? error;
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        await _store.finishAccountDeletion(uid);
        error = null;
        break;
      } catch (e) {
        error = e;
      }
    }
    if (error != null) {
      // The account is gone; only this device's bookkeeping is left. Sync
      // stays off, and the next app start finishes it.
      debugPrint('[account-deletion] local cleanup failed: $error');
      await _refreshPending();
      _fail(
        '계정과 클라우드 백업은 삭제됐어요. 이 기기의 연결 정보 정리는 앱을 '
        '다시 열면 마무리돼요. 이 기기의 노래와 폴더는 그대로예요.',
      );
      return;
    }
    await _auth.endGoogleSession();
    try {
      await _account.signOut();
    } catch (e) {
      debugPrint('[account-deletion] sign-out after deletion failed: $e');
    }
    _pending = null;
    _completedThisLaunch = true;
    final cloud = _cloud;
    cloud?.resetAfterAccountDeletion();
    cloud?.resumeAfterAccountDeletion();
    _message = null;
    _setStatus(AccountDeletionStatus.completed);
    final done = onCompleted;
    if (done != null) await _quiet(done);
  }

  /// The block could not be confirmed, so nothing was deleted. If the
  /// cloud says for sure there is no block and nothing had started yet,
  /// the local deletion record is dropped and sync resumes; otherwise
  /// (block may exist, or an earlier attempt got further) the deletion
  /// stays pending and can be continued.
  Future<void> _afterBlockFailure(String uid) async {
    var cancelled = false;
    if (_pending?.stage == AccountDeletionStage.blocking) {
      try {
        if (!await _eraser.deletionBlockExists(uid)) {
          await _store.cancelAccountDeletion(uid);
          cancelled = true;
        }
      } catch (e) {
        debugPrint('[account-deletion] block check failed: $e');
      }
    }
    if (cancelled) {
      _pending = null;
      _abortBeforeDeleting(
        '삭제를 시작하지 못했어요. 네트워크 연결을 확인한 뒤 다시 시도해 주세요. '
        '아무것도 삭제하지 않았어요.',
      );
      return;
    }
    await _refreshPending();
    _fail(
      '삭제를 시작하지 못했어요. 클라우드 백업은 삭제되지 않았어요. '
      '"계정 삭제 계속하기"로 다시 시도해 주세요. 이 기기의 노래와 폴더는 그대로예요.',
    );
  }

  /// Nothing was deleted: back to normal (sync resumes unless an earlier,
  /// unfinished deletion is still recorded).
  void _abortBeforeDeleting(String? message) {
    if (_pending == null) _cloud?.resumeAfterAccountDeletion();
    _message = message;
    _setStatus(
      message == null
          ? AccountDeletionStatus.idle
          : AccountDeletionStatus.failed,
    );
  }

  Future<void> _refreshPending() async {
    try {
      _pending = await _store.readPendingAccountDeletion() ?? _pending;
    } catch (_) {}
  }

  void _fail(String message) {
    _message = message;
    _setStatus(AccountDeletionStatus.failed);
  }

  void _setStatus(AccountDeletionStatus s) {
    _status = s;
    notifyListeners();
  }

  /// Dismisses a shown failure (the pending state, if any, stays).
  void clearMessage() {
    if (busy) return;
    _message = null;
    if (_status == AccountDeletionStatus.failed) {
      _status = AccountDeletionStatus.idle;
    }
    notifyListeners();
  }

  static Future<void> _quiet(Future<void> Function() f) async {
    try {
      await f();
    } catch (e) {
      debugPrint('[account-deletion] bookkeeping failed: $e');
    }
  }
}
