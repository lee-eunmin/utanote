import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';

import '../../theme/app_theme.dart';
import '../ad_unit_ids.dart';
import '../ads_consent_controller.dart';
import '../list_ad_source.dart';
import 'ump_consent_gateway.dart';

/// Ads are Android-only for now; iOS/desktop (and test hosts) get no ads.
bool get _adsSupported => Platform.isAndroid;

AdsConsentController? _consent;

/// Starts the UMP consent flow (once per launch). The Mobile Ads SDK is only
/// initialized, and ads only load, after consent allows ad requests. Not
/// awaited by `main()`, so app startup is never blocked by it.
AdsConsentController? startAds() {
  if (!_adsSupported) return null;
  return _consent ??= AdsConsentController(
    gateway: UmpConsentGateway(),
    initializeSdk: () => MobileAds.instance.initialize(),
  )..start();
}

ListAdSourceFactory? songListAdSourceFactory() {
  final consent = _consent;
  if (consent == null) return null;
  return () =>
      NativeListAdSource(adUnitId: kSongListNativeAdUnitId, consent: consent);
}

/// Native-template ads for a song list.
///
/// Ads are loaded lazily, only when their slot is first built (i.e. scrolled
/// near the viewport), and slots share a small fixed pool: slot `n` shows
/// pool ad `n % poolSize`. So rebuilds never reload an ad, a long list never
/// loads more than [poolSize] ads, and slots sharing an ad are
/// `poolSize * 10` songs apart, so they are never on screen (and never need
/// the same ad view) at the same time.
class NativeListAdSource implements ListAdSource {
  static const poolSize = 4;

  final String adUnitId;
  final AdsConsentController consent;
  final Map<int, _NativeAdHolder> _pool = {};

  NativeListAdSource({required this.adUnitId, required this.consent});

  @override
  Widget buildAd(BuildContext context, int slot) {
    final holder = _pool.putIfAbsent(
      slot % poolSize,
      () => _NativeAdHolder(adUnitId)..load(consent),
    );
    return _NativeAdCard(holder: holder, consent: consent);
  }

  @override
  void dispose() {
    for (final holder in _pool.values) {
      holder.dispose();
    }
    _pool.clear();
  }
}

class _NativeAdHolder extends ChangeNotifier {
  final String adUnitId;
  NativeAd? _ad;
  bool _loaded = false;
  bool _disposed = false;

  _NativeAdHolder(this.adUnitId);

  /// Non-null only once the ad has successfully loaded.
  NativeAd? get loadedAd => _loaded ? _ad : null;

  /// Requests the ad only once consent allows it (and the SDK is ready).
  Future<void> load(AdsConsentController consent) async {
    await consent.adsReady;
    if (_disposed || !consent.canRequestAds) return;
    _ad = NativeAd(
      adUnitId: adUnitId,
      request: const AdRequest(),
      nativeTemplateStyle: _templateStyle(),
      listener: NativeAdListener(
        onAdLoaded: (_) {
          if (_disposed) return;
          _loaded = true;
          notifyListeners();
        },
        // A failed slot simply stays zero-size; no retry this session.
        onAdFailedToLoad: (ad, _) {
          ad.dispose();
          _ad = null;
        },
      ),
    );
    unawaited(_ad!.load());
  }

  @override
  void dispose() {
    _disposed = true;
    _ad?.dispose();
    _ad = null;
    super.dispose();
  }
}

NativeTemplateStyle _templateStyle() => NativeTemplateStyle(
  templateType: TemplateType.small,
  mainBackgroundColor: AppColors.surfaceHigh,
  cornerRadius: 8,
  callToActionTextStyle: NativeTemplateTextStyle(
    textColor: Colors.black,
    backgroundColor: AppColors.accent,
    style: NativeTemplateFontStyle.bold,
    size: 13,
  ),
  primaryTextStyle: NativeTemplateTextStyle(
    textColor: AppColors.textPrimary,
    style: NativeTemplateFontStyle.bold,
    size: 14,
  ),
  secondaryTextStyle: NativeTemplateTextStyle(
    textColor: AppColors.textSecondary,
    size: 12,
  ),
  tertiaryTextStyle: NativeTemplateTextStyle(
    textColor: AppColors.textSecondary,
    size: 12,
  ),
);

/// A compact, clearly-labelled ad card. Deliberately styled unlike a song
/// row (boxed surface, "광고" label, no status bar/favorite) so it can't be
/// mistaken for a song. Zero-size until the ad has loaded, and hidden again
/// if consent is later withdrawn via the privacy options form.
class _NativeAdCard extends StatelessWidget {
  static const _templateHeight = 96.0;

  final _NativeAdHolder holder;
  final AdsConsentController consent;

  const _NativeAdCard({required this.holder, required this.consent});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([holder, consent]),
      builder: (context, _) {
        final ad = consent.canRequestAds ? holder.loadedAd : null;
        if (ad == null) return const SizedBox.shrink();
        return Container(
          margin: const EdgeInsets.symmetric(vertical: 10),
          padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
          decoration: BoxDecoration(
            color: AppColors.surfaceHigh,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppColors.hairline),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('광고', style: AppTextStyles.label),
              const SizedBox(height: 6),
              SizedBox(
                height: _templateHeight,
                child: AdWidget(ad: ad),
              ),
            ],
          ),
        );
      },
    );
  }
}
