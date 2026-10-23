import 'dart:async';
import 'dart:io' show Platform;

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:google_sign_in/google_sign_in.dart';

import '../../firebase_options.dart';
import '../../storage/android/sqlite_local_storage.dart';
import '../../storage/local_storage.dart';
import '../../sync/android/firestore_cloud_sync_backend.dart';
import '../../sync/cloud_sync_controller.dart';
import '../../sync/initial_sync_engine.dart';
import '../../sync/manual_sync.dart';
import '../account_controller.dart';
import '../auth_gateway.dart';

/// Sign-in is Android-only for now; iOS/desktop (and test hosts) get none.
bool get _accountSupported => Platform.isAndroid;

AccountController? _controller;

/// Creates the account controller and starts Firebase in the background.
/// Not awaited by `main()`: a slow or failing Firebase start never delays
/// or breaks app startup — sign-in just shows as unavailable.
AccountController? startAccount(LocalStorage storage) {
  if (!_accountSupported) return null;
  if (storage is! SqliteLocalStorage) return null;
  final existing = _controller;
  if (existing != null) return existing;
  final controller = AccountController(
    gateway: FirebaseAuthGateway(),
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
  _controller = controller;
  return controller..start();
}

class _SqliteBoundAccount implements BoundAccountSource {
  final SqliteLocalStorage _storage;

  _SqliteBoundAccount(this._storage);

  @override
  Future<String?> readBoundAccountUid() => _storage.readBoundAccountUid();
}

/// Firebase Authentication with a Google credential from Google Sign-In
/// (Android Credential Manager). Holds no app data.
class FirebaseAuthGateway implements AuthGateway {
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

  @override
  Future<AccountUser> signInWithGoogle() async {
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
