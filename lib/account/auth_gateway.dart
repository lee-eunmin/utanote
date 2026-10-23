/// Platform-neutral sign-in boundary. The Firebase/Google implementation
/// lives in `android/firebase_auth_gateway.dart`; tests use a fake.
///
/// Nothing here reads or writes songs, folders or any local database row.
library;

/// The signed-in cloud account, as much as the app needs to show.
class AccountUser {
  final String uid;
  final String? email;

  const AccountUser({required this.uid, this.email});

  @override
  bool operator ==(Object other) =>
      other is AccountUser && other.uid == uid && other.email == email;

  @override
  int get hashCode => Object.hash(uid, email);
}

/// The user closed the Google account picker without choosing an account.
class AccountSignInCancelled implements Exception {
  const AccountSignInCancelled();
}

/// Sign-in did not complete. [message] is user-facing (Korean); [detail] is
/// for logs only.
class AccountSignInFailure implements Exception {
  final String message;
  final String? detail;

  const AccountSignInFailure(this.message, {this.detail});

  @override
  String toString() => 'AccountSignInFailure($message, $detail)';
}

abstract class AuthGateway {
  /// Prepares the sign-in backend (e.g. Firebase). Returns false — and
  /// never throws — when it isn't available, e.g. no Firebase config.
  Future<bool> initialize();

  /// Current user now and on every change, including a session restored
  /// at startup. Only valid after [initialize] returned true.
  Stream<AccountUser?> userChanges();

  /// Shows the Google account picker and signs in to Firebase with it.
  /// Throws [AccountSignInCancelled] or [AccountSignInFailure].
  Future<AccountUser> signInWithGoogle();

  /// Ends the Firebase and Google sessions only. Never touches local data.
  Future<void> signOut();
}

/// Source of the cloud account this device's local database is bound to
/// (`sync_meta.account_uid`). Read-only: binding is written by the sync
/// layer after a successful first upload/restore, never by sign-in.
abstract class BoundAccountSource {
  Future<String?> readBoundAccountUid();
}

/// Optional extra of a [BoundAccountSource]: the email recorded with the
/// binding (`sync_meta.account_email_hint`). Read-only.
abstract class BoundAccountEmailSource {
  Future<String?> readBoundAccountEmailHint();
}

/// Optional: releases this device's binding to an earlier cloud account,
/// only after the user explicitly agreed (Phase B-5.1). Local only: never
/// deletes songs/folders, never uploads or merges.
abstract class PreviousBindingRelease {
  /// Throws if the device is no longer bound to [expectedBoundUid].
  Future<void> releasePreviousBinding({required String expectedBoundUid});
}

/// How a signed-in account relates to this device's local database.
enum AccountLinkStatus {
  /// The local database is not bound to any account yet.
  unlinked,

  /// Bound to this same account.
  sameAccount,

  /// Bound to a different account. Nothing may be merged or synced.
  otherAccount,

  /// Bound to a different uid that was recorded with the SAME Google email
  /// (e.g. the account was deleted and re-created, which gives a new uid).
  /// Nothing syncs; the user may explicitly release the old binding on
  /// this device and set up a new backup (Phase B-5.1).
  previousAccountSameEmail,
}

/// Same email, ignoring case and surrounding spaces. Missing/empty never
/// matches.
bool sameAccountEmail(String? a, String? b) {
  if (a == null || b == null) return false;
  final x = a.trim().toLowerCase();
  final y = b.trim().toLowerCase();
  return x.isNotEmpty && x == y;
}

AccountLinkStatus evaluateAccountLink({
  required String? boundUid,
  required String signedInUid,
}) {
  if (boundUid == null || boundUid.isEmpty) return AccountLinkStatus.unlinked;
  return boundUid == signedInUid
      ? AccountLinkStatus.sameAccount
      : AccountLinkStatus.otherAccount;
}
