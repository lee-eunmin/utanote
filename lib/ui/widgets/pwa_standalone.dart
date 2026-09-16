// Detects whether the app is running as an installed/standalone PWA
// (e.g. iOS "Add to Home Screen"). Only meaningful on web — the Android
// native build (dart:library.io) never needs this and gets a stub that
// always returns false, so it's never pulled into that build.
export 'pwa_standalone_web.dart'
    if (dart.library.io) 'pwa_standalone_stub.dart';
