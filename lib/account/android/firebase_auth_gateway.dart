import 'dart:async';
import 'dart:io' show Platform;

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:google_sign_in/google_sign_in.dart';

import '../../firebase_options.dart';
import '../../storage/android/sqlite_local_storage.dart';
import '../../storage/android/sqlite_sync_store.dart';
import '../../storage/local_storage.dart';
import '../../sync/account_data_deletion.dart';
import '../../sync/android/firestore_account_data_eraser.dart';
import '../../sync/android/firestore_cloud_sync_backend.dart';
import '../../sync/cloud_sync_controller.dart';
import '../../sync/initial_sync_engine.dart';
import '../../sync/manual_sync.dart';
import '../account_controller.dart';
import '../account_deletion.dart';
import '../auth_gateway.dart';

/// Sign-in is Android-only for now; iOS/desktop (and test hosts) get none.
bool get _accountSupported => Platform.isAndroid;

AccountController? _controller;

/// Creates the account controller and starts Firebase in the background.
/// Not awaited by `main()`: a slow or failing Firebase start never delays
/// or breaks app startup — sign-in just shows as unavailable.
AccountController? startAccount(
  LocalStorage storage, {
  Future<void> Function()? onAccountDeleted,
}) {
  if (!_accountSupported) return null;
  if (storage is! SqliteLocalStorage) return null;
  final existing = _controller;
  if (existing != null) return existing;
  final gateway = FirebaseAuthGateway();
  final controller = AccountController(
    gateway: gateway,
    boundAccount: _SqliteBoundAccount(storage),
  );
  // The first connection only runs when the user asks; two-way sync runs
  // on "지금 동기화" and automatically once the device is bound. Firestore
  // is only touched while signed in, i.e. after Firebase is initialized.
  final backend = FirestoreCloudSyncBackend();
  controller.cloudSync = CloudSyncController(
    engine: InitialSyncEngine(store: storage.syncStore, backend: backend),
    manual: ManualSyncEngine(store: storage.syncStore, backend: backend),
    // Phase B-4B: automatic sync for a bound device (start, foreground,
    // 5 s after user edits). Never for an unbound device.
    autoSync: const AutoSyncConfig(),
    account: controller,
  );
  // Phase B-5: "계정 및 클라우드 데이터 삭제". Hard-deletes only through its
  // own eraser; normal sync never deletes documents.
  final syncStore = storage.syncStore;
  if (syncStore is AccountDeletionStore) {
    final deletion = AccountDeletionController(
      account: controller,
      auth: gateway,
      store: syncStore as AccountDeletionStore,
      eraser: FirestoreAccountDataEraser(),
      onCompleted: onAccountDeleted,
    );
    controller.deletion = deletion;
    // An unfinished deletion from an earlier run keeps sync off.
    unawaited(deletion.load());
  }
  _controller = controller;
  return controller..start();
}

class _SqliteBoundAccount
    implements
        BoundAccountSource,
        BoundAccountEmailSource,
        PreviousBindingRelease {
  final SqliteLocalStorage _storage;

  _SqliteBoundAccount(this._storage);

  SqliteLocalSyncStore get _sync => _storage.syncStore as SqliteLocalSyncStore;

  @override
  Future<String?> readBoundAccountUid() => _storage.readBoundAccountUid();

  @override
  Future<String?> readBoundAccountEmailHint() =>
      _sync.readBoundAccountEmailHint();

  @override
  Future<void> releasePreviousBinding({required String expectedBoundUid}) =>
      _sync.releasePreviousBinding(expectedBoundUid: expectedBoundUid);
}

/// Firebase Authentication with a Google credential from Google Sign-In
/// (Android Credential Manager). Holds no app data.
class FirebaseAuthGateway implements AuthGateway, AccountDeletionAuth {
  static const _initTimeout = Duration(seconds: 10);
  static const _signInTimeout = Duration(seconds: 30);

  @override
  Future<bool> initialize() async {
    try {
      if (Firebase.apps.isEmpty) {
        await Firebase.initializeApp(
          options: DefaultFirebaseOptions.currentPlatform,
        ).timeout(_initTimeout);
      }
      await GoogleSignIn.instance.initialize().timeout(_initTimeout);
      return true;
    } catch (e) {
      // Typically: Firebase not configured yet (placeholder options or no
      // google-services.json). Sign-in is then simply unavailable.
      debugPrint('[account] Firebase/Google Sign-In unavailable: $e');
      return false;
    }
  }

  @override
  Stream<AccountUser?> userChanges() =>
      FirebaseAuth.instance.authStateChanges().map(_toAccountUser);

  /// Google account picker → Google ID token. Throws
  /// [AccountSignInCancelled] or [AccountSignInFailure].
  static Future<String> _googleIdToken() async {
    final google = GoogleSignIn.instance;
    if (!google.supportsAuthenticate()) {
      throw const AccountSignInFailure('이 기기에서는 Google 로그인을 사용할 수 없어요.');
    }

    final GoogleSignInAccount account;
    try {
      account = await google.authenticate();
    } on GoogleSignInException catch (e) {
      throw _mapGoogleError(e);
    }

    final idToken = account.authentication.idToken;
    if (idToken == null || idToken.isEmpty) {
      throw const AccountSignInFailure(
        '로그인 정보를 받지 못했어요. 잠시 후 다시 시도해 주세요.',
        detail: 'missing idToken',
      );
    }
    return idToken;
  }

  @override
  Future<AccountUser> signInWithGoogle() async {
    final idToken = await _googleIdToken();
    try {
      final result = await FirebaseAuth.instance
          .signInWithCredential(GoogleAuthProvider.credential(idToken: idToken))
          .timeout(_signInTimeout);
      final user = result.user;
      if (user == null) {
        throw const AccountSignInFailure(
          '로그인하지 못했어요. 잠시 후 다시 시도해 주세요.',
          detail: 'no Firebase user',
        );
      }
      return _toAccountUser(user)!;
    } on FirebaseAuthException catch (e) {
      // Don't leave a half-finished Google session behind.
      await _quietGoogleSignOut();
      throw AccountSignInFailure(
        e.code == 'network-request-failed'
            ? '네트워크 연결을 확인한 뒤 다시 시도해 주세요.'
            : '로그인하지 못했어요. 잠시 후 다시 시도해 주세요.',
        detail: 'FirebaseAuthException(${e.code})',
      );
    } on TimeoutException {
      await _quietGoogleSignOut();
      throw const AccountSignInFailure(
        '로그인 응답이 늦어요. 네트워크 연결을 확인해 주세요.',
        detail: 'timeout',
      );
    }
  }

  @override
  Future<void> signOut() async {
    Object? firstError;
    try {
      await FirebaseAuth.instance.signOut();
    } catch (e) {
      firstError = e;
    }
    try {
      await GoogleSignIn.instance.signOut();
    } catch (e) {
      firstError ??= e;
    }
    if (firstError != null) throw firstError;
  }

  // --- Phase B-5: account deletion -------------------------------------------

  @override
  String? get currentUid => FirebaseAuth.instance.currentUser?.uid;

  @override
  Future<AccountUser> reauthenticate() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      throw const AccountSignInFailure(
        '로그인 상태를 확인하지 못했어요. 다시 로그인해 주세요.',
        detail: 'no current user',
      );
    }
    final idToken = await _googleIdToken();
    try {
      final result = await user
          .reauthenticateWithCredential(
            GoogleAuthProvider.credential(idToken: idToken),
          )
          .timeout(_signInTimeout);
      final again = result.user ?? FirebaseAuth.instance.currentUser;
      if (again == null || again.uid != user.uid) {
        throw const AccountReauthMismatch();
      }
      return _toAccountUser(again)!;
    } on FirebaseAuthException catch (e) {
      if (e.code == 'user-mismatch') throw const AccountReauthMismatch();
      throw AccountSignInFailure(
        e.code == 'network-request-failed'
            ? '네트워크 연결을 확인한 뒤 다시 시도해 주세요.'
            : '본인 확인을 하지 못했어요. 잠시 후 다시 시도해 주세요.',
        detail: 'reauth FirebaseAuthException(${e.code})',
      );
    } on TimeoutException {
      throw const AccountSignInFailure(
        '응답이 늦어요. 네트워크 연결을 확인해 주세요.',
        detail: 'reauth timeout',
      );
    }
  }

  @override
  Future<void> deleteCurrentUser() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      throw const AccountDeletionAuthException(
        AccountDeletionAuthErrorKind.other,
        'no current user',
      );
    }
    try {
      await user.delete().timeout(_signInTimeout);
    } on FirebaseAuthException catch (e) {
      throw AccountDeletionAuthException(switch (e.code) {
        'requires-recent-login' =>
          AccountDeletionAuthErrorKind.requiresRecentLogin,
        'network-request-failed' => AccountDeletionAuthErrorKind.network,
        _ => AccountDeletionAuthErrorKind.other,
      }, 'FirebaseAuthException(${e.code})');
    } on TimeoutException {
      throw const AccountDeletionAuthException(
        AccountDeletionAuthErrorKind.network,
        'timeout',
      );
    }
  }

  @override
  Future<void> endGoogleSession() async {
    try {
      // Revokes this app's access to the Google account, not just the
      // local session.
      await GoogleSignIn.instance.disconnect();
    } catch (_) {
      await _quietGoogleSignOut();
    }
  }

  static Future<void> _quietGoogleSignOut() async {
    try {
      await GoogleSignIn.instance.signOut();
    } catch (_) {}
  }

  static AccountUser? _toAccountUser(User? user) =>
      user == null ? null : AccountUser(uid: user.uid, email: user.email);

  /// Note: on Android, a wrong SHA fingerprint / OAuth setup can surface as
  /// `canceled` too (Credential Manager can't tell them apart), so a
  /// "nothing happened" after choosing an account usually means config.
  static Exception _mapGoogleError(GoogleSignInException e) {
    switch (e.code) {
      case GoogleSignInExceptionCode.canceled:
        return const AccountSignInCancelled();
      case GoogleSignInExceptionCode.interrupted:
        return AccountSignInFailure(
          '로그인이 중단됐어요. 다시 시도해 주세요.',
          detail: 'google ${e.code.name}: ${e.description}',
        );
      case GoogleSignInExceptionCode.clientConfigurationError:
      case GoogleSignInExceptionCode.providerConfigurationError:
        return AccountSignInFailure(
          '로그인 설정에 문제가 있어요. 앱을 최신 버전으로 업데이트해 주세요.',
          detail: 'google ${e.code.name}: ${e.description}',
        );
      case GoogleSignInExceptionCode.uiUnavailable:
        return AccountSignInFailure(
          '지금은 Google 계정 선택 화면을 열 수 없어요.',
          detail: 'google ${e.code.name}: ${e.description}',
        );
      default:
        return AccountSignInFailure(
          '로그인하지 못했어요. 잠시 후 다시 시도해 주세요.',
          detail: 'google ${e.code.name}: ${e.description}',
        );
    }
  }
}
