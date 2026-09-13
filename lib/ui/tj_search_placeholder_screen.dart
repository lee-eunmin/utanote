import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'widgets/app_header.dart';
import 'widgets/responsive_center.dart';

/// Placeholder for the "TJ 검색" tab. No network/TJ search backend exists
/// yet — this intentionally only communicates that it's coming.
class TjSearchPlaceholderScreen extends StatelessWidget {
  const TjSearchPlaceholderScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: ResponsiveCenter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const AppHeader(),
                Expanded(
                  child: Center(
                    child: Padding(
                      padding: const EdgeInsets.all(32),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(
                            Icons.search_rounded,
                            size: 40,
                            color: AppColors.textTertiary,
                          ),
                          const SizedBox(height: 16),
                          const Text(
                            'TJ 검색은 준비 중이에요',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 8),
                          const Text(
                            'TJ 미디어 곡 검색 기능이 곧 추가될 예정입니다.',
                            textAlign: TextAlign.center,
                            style: AppTextStyles.meta,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
