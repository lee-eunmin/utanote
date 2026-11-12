import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:utanote/ads/native_ad_layout.dart';

void main() {
  test('Android keeps the small native template at 96', () {
    final l = SongListNativeAdLayout.forPlatform(TargetPlatform.android);
    expect(l.usesTemplate, isTrue);
    expect(l.factoryId, isNull);
    expect(l.height, 96);
  });

  test('iOS uses the custom factory with room for a 120pt MediaView', () {
    final l = SongListNativeAdLayout.forPlatform(TargetPlatform.iOS);
    expect(l.usesTemplate, isFalse);
    expect(l.factoryId, 'utanoteSongListNativeAd');
    expect(l.height, greaterThanOrEqualTo(120));
    expect(l.height, 132);
  });

  test('the iOS factory id matches the one registered in AppDelegate.swift',
      () {
    final swift = File('ios/Runner/AppDelegate.swift').readAsStringSync();
    expect(
      swift,
      contains('static let factoryId = "$kIosSongListNativeAdFactoryId"'),
    );
    expect(swift, contains('registerNativeAdFactory('));
    expect(swift, contains('mediaSide: CGFloat = 120'));
  });
}
