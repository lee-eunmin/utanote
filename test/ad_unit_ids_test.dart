import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:utanote/ads/ad_unit_ids.dart';

void main() {
  group('songListNativeAdUnitIdFor', () {
    test('Android release uses the existing production unit', () {
      expect(
        songListNativeAdUnitIdFor(TargetPlatform.android, release: true),
        'ca-app-pub-7771288156246683/7891912313',
      );
    });

    test('Android debug/profile uses Google\'s Android test unit', () {
      expect(
        songListNativeAdUnitIdFor(TargetPlatform.android, release: false),
        'ca-app-pub-3940256099942544/2247696110',
      );
    });

    test('iOS release uses the iOS production unit', () {
      expect(
        songListNativeAdUnitIdFor(TargetPlatform.iOS, release: true),
        'ca-app-pub-7771288156246683/5672319333',
      );
    });

    test('iOS debug/profile uses Google\'s iOS test unit', () {
      expect(
        songListNativeAdUnitIdFor(TargetPlatform.iOS, release: false),
        'ca-app-pub-3940256099942544/3986624511',
      );
    });

    test('other platforms get no ad unit', () {
      for (final platform in [
        TargetPlatform.macOS,
        TargetPlatform.windows,
        TargetPlatform.linux,
        TargetPlatform.fuchsia,
      ]) {
        for (final release in [true, false]) {
          expect(
            songListNativeAdUnitIdFor(platform, release: release),
            isNull,
            reason: '$platform release=$release',
          );
        }
      }
    });

    test('Android and iOS never share a unit', () {
      for (final release in [true, false]) {
        expect(
          songListNativeAdUnitIdFor(TargetPlatform.android, release: release),
          isNot(
            songListNativeAdUnitIdFor(TargetPlatform.iOS, release: release),
          ),
        );
      }
    });
  });

  group('songListNativeAdUnitId (running platform, test = non-release)', () {
    tearDown(() => debugDefaultTargetPlatformOverride = null);

    test('follows the target platform', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      expect(songListNativeAdUnitId, 'ca-app-pub-3940256099942544/2247696110');
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      expect(songListNativeAdUnitId, 'ca-app-pub-3940256099942544/3986624511');
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      expect(songListNativeAdUnitId, isNull);
    });
  });
}
