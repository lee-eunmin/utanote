import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kReleaseMode;

/// AdMob ad unit IDs, per platform.
///
/// Which native ad unit the main song list uses:
/// - Debug and profile builds (`flutter run`, `flutter run --profile`, tests):
///   Google's official native TEST unit for the platform, so development
///   never requests or clicks real ads (which can get the AdMob account
///   flagged).
/// - Release builds only: the platform's real UtaNote production native unit.
///
/// Web never loads ads (see `ads.dart`); other platforms get no ID.
const _androidTestNativeAdUnitId = 'ca-app-pub-3940256099942544/2247696110';
const _androidProductionNativeAdUnitId =
    'ca-app-pub-7771288156246683/7891912313';
const _iosTestNativeAdUnitId = 'ca-app-pub-3940256099942544/3986624511';
const _iosProductionNativeAdUnitId = 'ca-app-pub-7771288156246683/5672319333';

/// The song-list native ad unit for [platform]; null where ads aren't
/// supported. Pure, so the per-platform choice can be unit-tested.
String? songListNativeAdUnitIdFor(
  TargetPlatform platform, {
  required bool release,
}) {
  switch (platform) {
    case TargetPlatform.android:
      return release
          ? _androidProductionNativeAdUnitId
          : _androidTestNativeAdUnitId;
    case TargetPlatform.iOS:
      return release ? _iosProductionNativeAdUnitId : _iosTestNativeAdUnitId;
    default:
      return null;
  }
}

/// The song-list native ad unit for the running platform and build mode.
String? get songListNativeAdUnitId =>
    songListNativeAdUnitIdFor(defaultTargetPlatform, release: kReleaseMode);
