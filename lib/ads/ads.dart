/// Ads entry point. Picks the implementation at compile time, the same way
/// `storage/local_storage_factory.dart` does:
/// - `dart.library.io` present → `android/android_ads.dart` (google_mobile_ads;
///   still a no-op at runtime unless the platform is Android).
/// - otherwise (Web) → `ads_stub.dart`, so the ads plugin is never compiled
///   into the Web build and no ads are ever shown there.
library;

export 'ads_stub.dart' if (dart.library.io) 'android/android_ads.dart';
export 'ads_consent_controller.dart';
export 'list_ad_source.dart';
