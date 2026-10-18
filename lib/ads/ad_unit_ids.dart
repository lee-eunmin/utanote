import 'package:flutter/foundation.dart' show kReleaseMode;

/// AdMob ad unit IDs.
///
/// Which native ad unit the main song list uses:
/// - Debug and profile builds (`flutter run`, `flutter run --profile`, tests):
///   Google's official Android native TEST unit, so development never
///   requests or clicks real ads (which can get the AdMob account flagged).
/// - Release builds only (`flutter build apk/appbundle --release`): the real
///   UtaNote production native unit.
///
/// Web and iOS never load ads (see `ads.dart`), so these IDs are only used
/// on Android.
const _testNativeAdUnitId = 'ca-app-pub-3940256099942544/2247696110';
const _productionNativeAdUnitId = 'ca-app-pub-7771288156246683/7891912313';

const kSongListNativeAdUnitId = kReleaseMode
    ? _productionNativeAdUnitId
    : _testNativeAdUnitId;
