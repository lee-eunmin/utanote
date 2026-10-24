import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../theme/app_theme.dart';

/// Opens [uri] outside the app; true when it was handed off.
typedef ExternalUrlLauncher = Future<bool> Function(Uri uri);

Future<bool> _launchInBrowser(Uri uri) =>
    launchUrl(uri, mode: LaunchMode.externalApplication);

/// Replaced by tests with a fake so no real browser is started.
@visibleForTesting
ExternalUrlLauncher externalUrlLauncher = _launchInBrowser;

/// Only absolute http/https links with a host are opened.
bool isAllowedExternalUrl(Uri uri) =>
    (uri.scheme == 'http' || uri.scheme == 'https') && uri.host.isNotEmpty;

/// Opens [url] in the external browser. Never throws; when the link can't be
/// opened the user sees a short notice instead.
Future<bool> openExternalUrl(BuildContext context, String url) async {
  final uri = Uri.tryParse(url);
  var opened = false;
  if (uri != null && isAllowedExternalUrl(uri)) {
    try {
      opened = await externalUrlLauncher(uri);
    } catch (e) {
      debugPrint('[external_link] failed to open $uri: $e');
    }
  }
  if (!opened && context.mounted) {
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        key: const Key('externalLinkFailedDialog'),
        backgroundColor: AppColors.surfaceHigh,
        content: const Text(
          '링크를 열지 못했어요. 잠시 후 다시 시도해 주세요.',
          style: TextStyle(fontSize: 14, color: AppColors.textPrimary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('확인'),
          ),
        ],
      ),
    );
  }
  return opened;
}
