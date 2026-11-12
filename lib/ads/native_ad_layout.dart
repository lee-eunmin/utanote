import 'package:flutter/foundation.dart' show TargetPlatform;

/// Factory id of the iOS song-list native ad view. Must match
/// `SongListNativeAdFactory.factoryId` in `ios/Runner/AppDelegate.swift`,
/// where the factory is registered with the plugin.
const kIosSongListNativeAdFactoryId = 'utanoteSongListNativeAd';

/// How the song-list native ad is rendered on a platform.
///
/// - Android: the plugin's small native template, unchanged (96 high).
/// - iOS: a custom `GADNativeAdView` from [kIosSongListNativeAdFactoryId].
///   The iOS small template caps its MediaView at a quarter of the ad's
///   width (~84pt on a 390pt iPhone), below the 120x120pt AdMob requires
///   for video; the custom view has a fixed 120x120pt MediaView with 6pt
///   above and below, so the ad area is 132pt high.
class SongListNativeAdLayout {
  /// Null → use the small native template.
  final String? factoryId;

  /// Height of the native ad view inside the card, in logical pixels.
  final double height;

  const SongListNativeAdLayout._({this.factoryId, required this.height});

  static const androidTemplate = SongListNativeAdLayout._(height: 96);
  static const iosFactory = SongListNativeAdLayout._(
    factoryId: kIosSongListNativeAdFactoryId,
    height: 132,
  );

  bool get usesTemplate => factoryId == null;

  /// Pure, so the per-platform choice can be unit-tested.
  static SongListNativeAdLayout forPlatform(TargetPlatform platform) =>
      platform == TargetPlatform.iOS ? iosFactory : androidTemplate;
}
