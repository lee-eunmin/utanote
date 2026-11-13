import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';

import '../../theme/app_theme.dart';
import '../ad_unit_ids.dart';
import '../ads_consent_controller.dart';
import '../list_ad_source.dart';
import '../native_ad_layout.dart';
import 'ump_consent_gateway.dart';

/// Template on Android, custom iOS factory view on iOS (see
/// [SongListNativeAdLayout]).
final SongListNativeAdLayout _layout = SongListNativeAdLayout.forPlatform(
  defaultTargetPlatform,
);

/// Ads run on Android and iOS; desktop (and test hosts) get no ads.
bool get _adsSupported => Platform.isAndroid || Platform.isIOS;

/// Ad diagnostics, in every build mode (a handful of lines per launch), so
/// a release/TestFlight build can be checked from the device log
/// (Xcode/Console.app on iOS, `adb logcat` on Android): consent result, SDK
/// initialization, each native ad request and its result with the AdMob
/// error code/domain/message. Never logs anything about the user.
void _adsLog(String message) => debugPrint('[ads] $message');

/// AdMob test devices for this build, from
/// `--dart-define=ADMOB_TEST_DEVICE_IDS=<id>[,<id>...]` (empty by default).
///
/// Listed devices get Google test ads (labelled "Test Ad", safe to tap)
/// from the real production ad unit; every other device is unaffected. So
/// an internal TestFlight build can be checked end to end without real
/// impressions or clicks, and an id left in by mistake changes nothing for
/// users. The id is the hash the Google Mobile Ads SDK prints to the device
/// log on its first ad request ("To get test ads on this device, set: ...
/// testDeviceIdentifiers = @[ @"<id>" ]").
const _testDeviceIdsDefine = String.fromEnvironment('ADMOB_TEST_DEVICE_IDS');

List<String> _testDeviceIds() => _testDeviceIdsDefine
    .split(',')
    .map((s) => s.trim())
    .where((s) => s.isNotEmpty)
    .toList();

AdsConsentController? _consent;

/// Starts the UMP consent flow (once per launch). The Mobile Ads SDK is only
/// initialized, and ads only load, after consent allows ad requests. Not
/// awaited by `main()`, so app startup is never blocked by it.
AdsConsentController? startAds() {
  if (!_adsSupported) return null;
  final existing = _consent;
  if (existing != null) return existing;
  final consent = _consent = AdsConsentController(
    gateway: UmpConsentGateway(),
    initializeSdk: _initializeSdk,
  );
  unawaited(
    consent.start().then((_) {
      _adsLog(
        'consent flow done: canRequestAds=${consent.canRequestAds}, '
        'privacyOptionsRequired=${consent.privacyOptionsRequired}',
      );
    }),
  );
  return consent;
}

Future<void> _initializeSdk() async {
  final testDevices = _testDeviceIds();
  if (testDevices.isNotEmpty) {
    await MobileAds.instance.updateRequestConfiguration(
      RequestConfiguration(testDeviceIds: testDevices),
    );
    _adsLog('test device ids set (${testDevices.length})');
  }
  final status = await MobileAds.instance.initialize();
  _adsLog(
    'Mobile Ads initialized: ${status.adapterStatuses.entries.map(
      (e) => '${e.key}=${e.value.state.name}',
    ).join(', ')}',
  );
}

ListAdSourceFactory? songListAdSourceFactory() {
  final consent = _consent;
  final adUnitId = songListNativeAdUnitId;
  if (consent == null || adUnitId == null) return null;
  return () => NativeListAdSource(adUnitId: adUnitId, consent: consent);
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
    if (_disposed) return;
    if (!consent.canRequestAds) {
      _adsLog('native ad not requested: consent no longer allows ads');
      return;
    }
    _adsLog(
      'requesting native ad: unit=$adUnitId, '
      '${_layout.factoryId ?? 'small template'}',
    );
    _ad = NativeAd(
      adUnitId: adUnitId,
      request: const AdRequest(),
      factoryId: _layout.factoryId,
      nativeTemplateStyle: _layout.usesTemplate ? _templateStyle() : null,
      listener: NativeAdListener(
        onAdLoaded: (ad) {
          final info = (ad as NativeAd).responseInfo;
          _adsLog(
            'native ad loaded: responseId=${info?.responseId}, '
            'adapter=${info?.mediationAdapterClassName}',
          );
          if (_disposed) return;
          _loaded = true;
          notifyListeners();
        },
        // A failed slot simply stays zero-size; no retry this session.
        onAdFailedToLoad: (ad, error) {
          _adsLog(
            'native ad failed to load: code=${error.code}, '
            'domain=${error.domain}, message=${error.message}, '
            'responseId=${error.responseInfo?.responseId}',
          );
          ad.dispose();
          _ad = null;
        },
      ),
    );
    final ad = _ad!;
    // The request itself can be refused before any listener callback, e.g.
    // on iOS when the native ad factory isn't registered ("Can't find
    // NativeAdFactory"). Same as a failed load: the slot stays zero-size,
    // no retry, no uncaught error.
    unawaited(
      ad.load().catchError((Object e) {
        _adsLog('native ad request failed: $e');
        if (identical(_ad, ad)) _ad = null;
        unawaited(ad.dispose());
      }),
    );
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
                height: _layout.height,
                child: AdWidget(ad: ad),
              ),
            ],
          ),
        );
      },
    );
  }
}
