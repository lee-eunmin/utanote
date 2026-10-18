import 'ads_consent_controller.dart';
import 'list_ad_source.dart';

/// No ads and no consent flow on this platform.
AdsConsentController? startAds() => null;

/// No ads on this platform.
ListAdSourceFactory? songListAdSourceFactory() => null;
