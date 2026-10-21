/// Account (sign-in) entry point. Picks the implementation at compile time,
/// like `ads/ads.dart`:
/// - `dart.library.io` → `android/firebase_auth_gateway.dart` (Firebase Auth
///   + Google Sign-In; still returns null at runtime unless on Android).
/// - otherwise (Web) → `account_stub.dart`: no sign-in, and no Firebase
///   code in the Web build.
library;

export 'account_stub.dart' if (dart.library.io) 'android/firebase_auth_gateway.dart';
export 'account_controller.dart';
export 'auth_gateway.dart';
