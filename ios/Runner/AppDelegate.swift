import Flutter
import GoogleMobileAds
import UIKit
import google_mobile_ads

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    // After the plugins are registered: the factory is looked up through
    // the google_mobile_ads plugin instance in this registry.
    let registered = FLTGoogleMobileAdsPlugin.registerNativeAdFactory(
      engineBridge.pluginRegistry,
      factoryId: SongListNativeAdFactory.factoryId,
      nativeAdFactory: SongListNativeAdFactory()
    )
    if !registered {
      NSLog("[ads] song list native ad factory was not registered")
    }
  }
}

/// iOS song-list native ad view (Dart: `SongListNativeAdLayout.iosFactory`).
///
/// Replaces the plugin's small template on iOS only: that template caps its
/// MediaView at a quarter of the ad width (~84pt on a 390pt iPhone), below
/// the 120x120pt AdMob requires for video. Same look as the small template
/// card: media on the left, headline / body / advertiser and the CTA on the
/// right, UtaNote colors. Flutter gives the view 132pt of height (120pt
/// media + 6pt above and below); the "광고" label is drawn by Flutter above it.
final class SongListNativeAdFactory: NSObject, FLTNativeAdFactory {
  /// Must match `kIosSongListNativeAdFactoryId` in
  /// `lib/ads/native_ad_layout.dart`.
  static let factoryId = "utanoteSongListNativeAd"

  private static let mediaSide: CGFloat = 120
  private static let gap: CGFloat = 10
  private static let ctaHeight: CGFloat = 30

  // AppColors in lib/theme/app_theme.dart.
  private static let surfaceHigh = UIColor(rgb: 0x1E1E22)
  private static let surfacePressed = UIColor(rgb: 0x26262B)
  private static let accent = UIColor(rgb: 0xCC9A4C)
  private static let textPrimary = UIColor(rgb: 0xF3F1ED)
  private static let textSecondary = UIColor(rgb: 0x9A99A1)

  func createNativeAd(
    _ nativeAd: NativeAd,
    customOptions: [AnyHashable: Any]? = nil
  ) -> NativeAdView? {
    let adView = NativeAdView()
    adView.backgroundColor = Self.surfaceHigh

    // Media: fixed 120x120pt (AdMob minimum for video), never stretched.
    let media = MediaView()
    media.translatesAutoresizingMaskIntoConstraints = false
    media.contentMode = .scaleAspectFit
    media.backgroundColor = Self.surfacePressed
    media.layer.cornerRadius = 8
    media.clipsToBounds = true
    media.mediaContent = nativeAd.mediaContent

    let icon = UIImageView()
    icon.translatesAutoresizingMaskIntoConstraints = false
    icon.contentMode = .scaleAspectFit
    icon.layer.cornerRadius = 4
    icon.clipsToBounds = true
    icon.image = nativeAd.icon?.image
    icon.isHidden = nativeAd.icon == nil

    let headline = Self.label(size: 14, weight: .bold, color: Self.textPrimary, lines: 2)
    headline.text = nativeAd.headline

    let body = Self.label(size: 12, weight: .regular, color: Self.textSecondary, lines: 2)
    body.text = nativeAd.body
    body.isHidden = nativeAd.body?.isEmpty ?? true
    // Gives way first when the text column is short of room.
    body.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

    let advertiser = Self.label(
      size: 12, weight: .regular, color: Self.textSecondary, lines: 1)
    advertiser.text = nativeAd.advertiser
    advertiser.isHidden = nativeAd.advertiser?.isEmpty ?? true

    let cta = UIButton(type: .custom)
    cta.translatesAutoresizingMaskIntoConstraints = false
    cta.backgroundColor = Self.accent
    cta.layer.cornerRadius = 8
    cta.setTitleColor(.black, for: .normal)
    cta.titleLabel?.font = .systemFont(ofSize: 13, weight: .bold)
    cta.titleLabel?.lineBreakMode = .byTruncatingTail
    cta.setTitle(nativeAd.callToAction, for: .normal)
    cta.isHidden = nativeAd.callToAction?.isEmpty ?? true
    // The SDK handles taps on the ad view; the button must not take them.
    cta.isUserInteractionEnabled = false

    let titleRow = UIStackView(arrangedSubviews: [icon, headline])
    titleRow.axis = .horizontal
    titleRow.alignment = .top
    titleRow.spacing = 6

    let text = UIStackView(arrangedSubviews: [titleRow, body, advertiser])
    text.translatesAutoresizingMaskIntoConstraints = false
    text.axis = .vertical
    text.alignment = .fill
    text.spacing = 3

    adView.addSubview(media)
    adView.addSubview(text)
    adView.addSubview(cta)

    let textBottom = text.bottomAnchor.constraint(
      lessThanOrEqualTo: cta.topAnchor, constant: -6)
    NSLayoutConstraint.activate([
      media.leadingAnchor.constraint(equalTo: adView.leadingAnchor),
      media.centerYAnchor.constraint(equalTo: adView.centerYAnchor),
      media.widthAnchor.constraint(equalToConstant: Self.mediaSide),
      media.heightAnchor.constraint(equalToConstant: Self.mediaSide),

      icon.widthAnchor.constraint(equalToConstant: 20),
      icon.heightAnchor.constraint(equalToConstant: 20),

      text.leadingAnchor.constraint(equalTo: media.trailingAnchor, constant: Self.gap),
      text.trailingAnchor.constraint(equalTo: adView.trailingAnchor),
      text.topAnchor.constraint(equalTo: media.topAnchor),
      textBottom,

      cta.leadingAnchor.constraint(equalTo: media.trailingAnchor, constant: Self.gap),
      cta.trailingAnchor.constraint(equalTo: adView.trailingAnchor),
      cta.bottomAnchor.constraint(equalTo: media.bottomAnchor),
      cta.heightAnchor.constraint(equalToConstant: Self.ctaHeight),
    ])

    // Register the asset views, then the ad (this makes the view clickable
    // and lets the SDK record impressions).
    adView.mediaView = media
    adView.iconView = icon
    adView.headlineView = headline
    adView.bodyView = body
    adView.advertiserView = advertiser
    adView.callToActionView = cta
    adView.nativeAd = nativeAd
    return adView
  }

  private static func label(
    size: CGFloat, weight: UIFont.Weight, color: UIColor, lines: Int
  ) -> UILabel {
    let label = UILabel()
    label.translatesAutoresizingMaskIntoConstraints = false
    label.font = .systemFont(ofSize: size, weight: weight)
    label.textColor = color
    label.numberOfLines = lines
    label.lineBreakMode = .byTruncatingTail
    return label
  }
}

private extension UIColor {
  convenience init(rgb: UInt32) {
    self.init(
      red: CGFloat((rgb >> 16) & 0xFF) / 255,
      green: CGFloat((rgb >> 8) & 0xFF) / 255,
      blue: CGFloat(rgb & 0xFF) / 255,
      alpha: 1
    )
  }
}
