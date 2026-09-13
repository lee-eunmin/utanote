import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';

/// The app's editorial header: the UTANOTE wordmark, an optional secondary
/// line (e.g. a song/folder count), and an optional trailing action —
/// rendered inside the same responsive content width as the rest of the
/// screen rather than a full-width system AppBar.
class AppHeader extends StatelessWidget {
  final String? subtitle;
  final Widget? trailing;

  const AppHeader({super.key, this.subtitle, this.trailing});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 8, 2, 18),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('UTANOTE', style: AppTextStyles.brand),
                if (subtitle != null) ...[
                  const SizedBox(height: 3),
                  Text(subtitle!, style: AppTextStyles.meta),
                ],
              ],
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

/// Compact square icon action used in [AppHeader.trailing] — a subtle
/// tinted surface rather than a floating filled/pill button.
class HeaderIconButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onPressed;

  const HeaderIconButton({
    super.key,
    required this.icon,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.surfaceHigh,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onPressed,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Icon(icon, size: 20, color: AppColors.textPrimary),
        ),
      ),
    );
  }
}
