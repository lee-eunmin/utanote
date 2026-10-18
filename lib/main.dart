import 'package:flutter/material.dart';

import 'ads/ads.dart';
import 'storage/local_storage.dart';
import 'storage/local_storage_factory.dart';
import 'theme/app_theme.dart';
import 'ui/app_shell.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Android only: kicks off the UMP consent flow without awaiting it, so a
  // slow or failing consent request never delays or blocks startup. Ads stay
  // disabled until consent allows them (null on Web/iOS: no ads, no UMP).
  final adsConsent = startAds();
  final storage = createLocalStorage();
  await storage.init();
  runApp(
    UtaNoteApp(
      storage: storage,
      songListAdSourceFactory: songListAdSourceFactory(),
      adsConsent: adsConsent,
    ),
  );
}

class UtaNoteApp extends StatelessWidget {
  final LocalStorage storage;

  /// In-list native ads for the main song list (Android only). Null → no ads.
  final ListAdSourceFactory? songListAdSourceFactory;

  /// Ad consent state (Android only). Null → no ads, no privacy entry.
  final AdsConsentController? adsConsent;

  const UtaNoteApp({
    super.key,
    required this.storage,
    this.songListAdSourceFactory,
    this.adsConsent,
  });

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'UtaNote',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      home: AppShell(
        storage: storage,
        songListAdSourceFactory: songListAdSourceFactory,
        adsConsent: adsConsent,
      ),
    );
  }
}
