import 'dart:async';

import 'package:flutter/foundation.dart';

/// The subset of Google's UMP (User Messaging Platform) consent API the app
/// uses, as Futures. The Android implementation wraps `google_mobile_ads`'
/// `ConsentInformation`/`ConsentForm`; tests use a fake. Each method may
/// throw on failure.
abstract class ConsentGateway {
  /// `ConsentInformation.requestConsentInfoUpdate`.
  Future<void> requestConsentInfoUpdate();

  /// `ConsentForm.loadAndShowConsentFormIfRequired`.
  Future<void> loadAndShowConsentFormIfRequired();

  /// `ConsentInformation.canRequestAds`.
  Future<bool> canRequestAds();

  /// `getPrivacyOptionsRequirementStatus() == required`.
  Future<bool> isPrivacyOptionsRequired();

  /// `ConsentForm.showPrivacyOptionsForm`.
  Future<void> showPrivacyOptionsForm();
}

/// Gates AdMob on the user's consent.
///
/// [start] runs once per app launch: refresh consent info → show the consent
/// form if required → check `canRequestAds()`. Errors at any step are only
/// logged (debug builds); `canRequestAds()` is checked regardless, since
/// consent from a previous session may still allow ads. The Mobile Ads SDK
/// is initialized, and [adsReady] completes, at most once — the first time
/// `canRequestAds()` is true — no matter how many paths (startup, privacy
/// options form) report that ads are allowed.
class AdsConsentController extends ChangeNotifier {
  final ConsentGateway gateway;
  final Future<void> Function() initializeSdk;
  final void Function(String message) _log;

  AdsConsentController({
    required this.gateway,
    required this.initializeSdk,
    void Function(String message)? log,
  }) : _log = log ?? _debugLog;

  static void _debugLog(String message) {
    if (kDebugMode) debugPrint('[ads consent] $message');
  }

  final _adsReady = Completer<void>();
  Future<void>? _started;
  Future<void>? _enabling;
  bool _canRequestAds = false;
  bool _privacyOptionsRequired = false;
  bool _disposed = false;

  /// Whether ads may currently be requested/shown (latest `canRequestAds()`).
  bool get canRequestAds => _canRequestAds;

  /// Whether a "privacy settings" entry must be offered to the user.
  bool get privacyOptionsRequired => _privacyOptionsRequired;

  /// Completes once consent first allows ad requests and the SDK has been
  /// initialized. Never completes if consent never allows ads. No ad may be
  /// requested before this.
  Future<void> get adsReady => _adsReady.future;

  /// Runs the startup consent flow. Idempotent; never throws.
  Future<void> start() => _started ??= _runConsentFlow();

  Future<void> _runConsentFlow() async {
    try {
      await gateway.requestConsentInfoUpdate();
      try {
        await gateway.loadAndShowConsentFormIfRequired();
      } catch (e) {
        _log('consent form failed: $e');
      }
    } catch (e) {
      _log('consent info update failed: $e');
    }
    await _refresh();
  }

  /// Re-opens the UMP privacy options form, then re-checks consent. Never
  /// throws.
  Future<void> showPrivacyOptions() async {
    try {
      await gateway.showPrivacyOptionsForm();
    } catch (e) {
      _log('privacy options form failed: $e');
    }
    await _refresh();
  }

  Future<void> _refresh() async {
    final canRequest = await _safely(gateway.canRequestAds, 'canRequestAds');
    final privacyRequired = await _safely(
      gateway.isPrivacyOptionsRequired,
      'privacy options status',
    );
    if (_disposed) return;
    _canRequestAds = canRequest;
    _privacyOptionsRequired = privacyRequired;
    notifyListeners();
    if (canRequest) await _enableAdsOnce();
  }

  Future<bool> _safely(Future<bool> Function() check, String what) async {
    try {
      return await check();
    } catch (e) {
      _log('$what failed: $e');
      return false;
    }
  }

  Future<void> _enableAdsOnce() => _enabling ??= () async {
    try {
      await initializeSdk();
    } catch (e) {
      // Ads will simply fail to load (and be omitted); never block the app.
      _log('Mobile Ads initialization failed: $e');
    }
    _adsReady.complete();
  }();

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
