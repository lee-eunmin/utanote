import 'package:flutter/material.dart';

import 'account/account.dart';
import 'ads/ads.dart';
import 'storage/local_storage.dart';
import 'storage/local_storage_factory.dart';
import 'storage/observed_local_storage.dart';
import 'theme/app_theme.dart';
import 'ui/app_shell.dart';
import 'ui/backup_prompt.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Android only: kicks off the UMP consent flow without awaiting it, so a
  // slow or failing consent request never delays or blocks startup. Ads stay
  // disabled until consent allows them (null on Web/iOS: no ads, no UMP).
  final adsConsent = startAds();
  final storage = createLocalStorage();
  await storage.init();
  // Android only: starts Firebase sign-in in the background (not awaited).
  // If Firebase isn't configured or fails, sign-in is just unavailable;
  // the app and its local data are unaffected. Null on Web.
  final account = startAccount(storage);
  final cloudSync = account?.cloudSync;
  runApp(
    UtaNoteApp(
      // User writes made through the UI schedule an automatic sync (only
      // ever runs on a device bound to the signed-in account).
      storage: cloudSync == null
          ? storage
          : ObservedLocalStorage(
              storage,
              onUserDataChanged: cloudSync.onLocalDataChanged,
            ),
      songListAdSourceFactory: songListAdSourceFactory(),
      adsConsent: adsConsent,
      account: account,
      backupPromptPrefs:
          cloudSync == null ? null : SharedPreferencesBackupPromptPrefs(),
    ),
  );
}

class UtaNoteApp extends StatelessWidget {
  final LocalStorage storage;

  /// In-list native ads for the main song list (Android only). Null → no ads.
  final ListAdSourceFactory? songListAdSourceFactory;

  /// Ad consent state (Android only). Null → no ads, no privacy entry.
  final AdsConsentController? adsConsent;

  /// Google sign-in (Android only). Null → no account entry.
  final AccountController? account;

  /// Where the start-up backup prompt remembers "나중에". Null → no prompt.
  final BackupPromptPrefs? backupPromptPrefs;

  /// Settle time before the backup prompt is considered.
  final Duration backupPromptDelay;

  /// Clock for the prompt's snooze (UTC ms). Null → real time.
  final int Function()? backupPromptNow;

  const UtaNoteApp({
    super.key,
    required this.storage,
    this.songListAdSourceFactory,
    this.adsConsent,
    this.account,
    this.backupPromptPrefs,
    this.backupPromptDelay = const Duration(milliseconds: 1500),
    this.backupPromptNow,
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
        account: account,
        backupPromptPrefs: backupPromptPrefs,
        backupPromptDelay: backupPromptDelay,
        backupPromptNow: backupPromptNow,
      ),
    );
  }
}
