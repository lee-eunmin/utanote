import 'dart:js_interop';

@JS('window.matchMedia')
external _MediaQueryList _matchMedia(JSString query);

extension type _MediaQueryList._(JSObject _) implements JSObject {
  external bool get matches;
}

@JS('navigator.standalone')
external JSBoolean? get _navigatorStandalone;

/// Whether this web session is running as an installed, standalone PWA —
/// iOS "Add to Home Screen" (`navigator.standalone`), or any browser's
/// `display-mode: standalone` (the general CSS/PWA signal, which iOS's
/// home-screen web apps also match).
///
/// This matters because iOS's `env(safe-area-inset-bottom)` — and so
/// Flutter web's `MediaQuery.padding.bottom` — can report 0 in standalone
/// mode even though the OS still reserves a home-indicator gesture strip
/// at the bottom of the screen that silently swallows touches there.
/// Callers use this signal to force a large-enough minimum bottom padding
/// instead of trusting the reported inset.
bool isPwaStandalone() {
  try {
    if (_matchMedia('(display-mode: standalone)'.toJS).matches) return true;
  } catch (_) {
    // matchMedia should always exist, but never let detection crash render.
  }
  try {
    if (_navigatorStandalone?.toDart ?? false) return true;
  } catch (_) {
    // navigator.standalone is an iOS-Safari-only extension; absent (not
    // thrown) elsewhere, but guard anyway since this must never crash.
  }
  return false;
}
