import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';

import '../ads_consent_controller.dart';

/// Optional UMP debug settings for testing the consent form outside the EEA.
/// Off unless explicitly passed, and ignored entirely in release builds:
///
///   flutter run --dart-define=UMP_DEBUG_GEOGRAPHY=eea \
///               --dart-define=UMP_TEST_DEVICE_IDS=HASHED_ID_FROM_LOGCAT
///
/// `UMP_DEBUG_GEOGRAPHY`: `eea`, `other`, or `regulated_us_state`.
/// `UMP_TEST_DEVICE_IDS`: comma-separated; UMP logs the device's hashed ID
/// to logcat on the first consent request. Use `ConsentInformation.reset()`
/// (or clear app data) to see the form again.
const _debugGeography = String.fromEnvironment('UMP_DEBUG_GEOGRAPHY');
const _testDeviceIds = String.fromEnvironment('UMP_TEST_DEVICE_IDS');

ConsentDebugSettings? _debugSettings() {
  if (kReleaseMode) return null;
  final geography = switch (_debugGeography) {
    'eea' => DebugGeography.debugGeographyEea,
    'other' => DebugGeography.debugGeographyOther,
    'regulated_us_state' => DebugGeography.debugGeographyRegulatedUsState,
    _ => null,
  };
  final ids = _testDeviceIds
      .split(',')
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toList();
  if (geography == null && ids.isEmpty) return null;
  return ConsentDebugSettings(debugGeography: geography, testIdentifiers: ids);
}

class _UmpFormException implements Exception {
  final FormError error;

  _UmpFormException(this.error);

  @override
  String toString() => 'FormError ${error.errorCode}: ${error.message}';
}

/// [ConsentGateway] backed by the UMP APIs bundled in `google_mobile_ads`.
class UmpConsentGateway implements ConsentGateway {
  @override
  Future<void> requestConsentInfoUpdate() {
    final done = Completer<void>();
    try {
      ConsentInformation.instance.requestConsentInfoUpdate(
        ConsentRequestParameters(consentDebugSettings: _debugSettings()),
        () => done.complete(),
        (error) => done.completeError(_UmpFormException(error)),
      );
    } catch (e) {
      done.completeError(e);
    }
    return done.future;
  }

  @override
  Future<void> loadAndShowConsentFormIfRequired() =>
      _formResult(ConsentForm.loadAndShowConsentFormIfRequired);

  @override
  Future<void> showPrivacyOptionsForm() =>
      _formResult(ConsentForm.showPrivacyOptionsForm);

  @override
  Future<bool> canRequestAds() => ConsentInformation.instance.canRequestAds();

  @override
  Future<bool> isPrivacyOptionsRequired() async =>
      await ConsentInformation.instance.getPrivacyOptionsRequirementStatus() ==
      PrivacyOptionsRequirementStatus.required;

  /// Adapts a UMP "dismissed with optional FormError" callback API to a
  /// Future that fails on a FormError or a platform-channel error.
  static Future<void> _formResult(
    Future<void> Function(OnConsentFormDismissedListener) show,
  ) {
    final done = Completer<void>();
    show((error) {
      if (done.isCompleted) return;
      error == null
          ? done.complete()
          : done.completeError(_UmpFormException(error));
    }).catchError((Object e) {
      if (!done.isCompleted) done.completeError(e);
    });
    return done.future;
  }
}
