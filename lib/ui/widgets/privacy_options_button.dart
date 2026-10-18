import 'package:flutter/material.dart';

import '../../ads/ads_consent_controller.dart';
import 'app_header.dart';

/// Header entry that re-opens the UMP privacy options (ad consent) form.
/// Only rendered when UMP reports privacy options are required (e.g. for
/// EEA/UK/Switzerland users); otherwise, and on Web, it takes no space.
class PrivacyOptionsButton extends StatelessWidget {
  final AdsConsentController? consent;

  const PrivacyOptionsButton({super.key, required this.consent});

  @override
  Widget build(BuildContext context) {
    final consent = this.consent;
    if (consent == null) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: consent,
      builder: (context, _) {
        if (!consent.privacyOptionsRequired) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.only(right: 8),
          child: Tooltip(
            message: '개인정보 설정',
            child: HeaderIconButton(
              key: const Key('privacyOptionsButton'),
              icon: Icons.privacy_tip_outlined,
              onPressed: consent.showPrivacyOptions,
            ),
          ),
        );
      },
    );
  }
}
