import 'dart:math' as math;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import 'pwa_standalone.dart';

/// Extra bottom padding reserved on web, on top of whatever safe-area inset
/// MediaQuery reports, for ordinary mobile browser tabs (Safari, in-app
/// browsers like KakaoTalk). Those report a real, usable
/// `safe-area-inset-bottom`, so this is just a small cosmetic floor.
const _webMinBottomPadding = 12.0;

/// Minimum bottom padding *guaranteed* (not just added) when running as an
/// installed iOS PWA (`isPwaStandalone()`). In that mode iOS's
/// `env(safe-area-inset-bottom)` — and so Flutter web's
/// `MediaQuery.padding.bottom` — can report 0, even though the OS still
/// reserves a real home-indicator gesture strip at the bottom of the screen
/// that silently swallows touches. If the tab bar's hit area is placed in
/// that strip, taps are eaten by the OS before they ever reach Flutter —
/// they don't just look wrong, they stop registering entirely. 34px matches
/// the actual home-indicator height Apple uses on notched iPhones, so this
/// floor is enough even when the reported inset can't be trusted.
const _iosPwaStandaloneMinBottomPadding = 34.0;

class _NavDestination {
  final IconData icon;
  final String label;

  const _NavDestination(this.icon, this.label);
}

const _destinations = [
  _NavDestination(Icons.queue_music_rounded, '노래 목록'),
  _NavDestination(Icons.folder_rounded, '폴더'),
  _NavDestination(Icons.search_rounded, 'TJ 검색'),
];

/// Compact bottom navigation: icon, label, and a thin sliding indicator line
/// above the active tab — no pill-shaped selection background. On wide
/// (desktop/web) viewports the bar's background spans the full width but its
/// items are constrained to the same content column as the rest of the app.
class AppBottomNav extends StatelessWidget {
  final int currentIndex;
  final ValueChanged<int> onTap;

  const AppBottomNav({
    super.key,
    required this.currentIndex,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    // On web, pad the bar ourselves (safe-area inset + a guaranteed floor)
    // and tell SafeArea to leave the bottom alone so the two don't stack.
    // Native (Android) keeps the original SafeArea-only behavior untouched.
    //
    // In iOS PWA standalone mode the reported inset can't be trusted (see
    // `_iosPwaStandaloneMinBottomPadding`), so there the floor is applied as
    // a guaranteed minimum on the *total* padding rather than just added on
    // top — otherwise a 0 inset would still leave only the small cosmetic
    // web floor, which sits inside the home-indicator's swallow zone.
    final reportedBottomPadding =
        MediaQuery.of(context).padding.bottom + _webMinBottomPadding;
    final webBottomPadding = kIsWeb && isPwaStandalone()
        ? math.max(reportedBottomPadding, _iosPwaStandaloneMinBottomPadding)
        : reportedBottomPadding;

    return Container(
      decoration: const BoxDecoration(
        color: AppColors.bg,
        border: Border(top: BorderSide(color: AppColors.hairline)),
      ),
      child: Padding(
        padding: EdgeInsets.only(bottom: kIsWeb ? webBottomPadding : 0),
        child: SafeArea(
          top: false,
          bottom: !kIsWeb,
          // Fix the height *before* Align: Scaffold gives the
          // bottomNavigationBar slot a bounded-but-loose height, and an
          // Align (unlike a Center with a tightly-sized child) expands to
          // fill any bounded height it's given rather than shrink-wrapping
          // its child — without this SizedBox the whole bar (and its tap
          // targets) would stretch to fill the screen instead of staying a
          // compact strip.
          child: SizedBox(
            height: 58,
            child: Align(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 640),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final itemWidth =
                        constraints.maxWidth / _destinations.length;
                    return Stack(
                      children: [
                        AnimatedPositioned(
                          duration: const Duration(milliseconds: 220),
                          curve: Curves.easeOutCubic,
                          left: itemWidth * currentIndex,
                          top: 0,
                          width: itemWidth,
                          height: 2.5,
                          child: Center(
                            child: Container(
                              width: 22,
                              height: 2.5,
                              decoration: BoxDecoration(
                                color: AppColors.accent,
                                borderRadius: BorderRadius.circular(2),
                              ),
                            ),
                          ),
                        ),
                        Row(
                          children: List.generate(_destinations.length, (i) {
                            final destination = _destinations[i];
                            final selected = i == currentIndex;
                            final color = selected
                                ? AppColors.textPrimary
                                : AppColors.textTertiary;
                            return Expanded(
                              child: InkWell(
                                key: Key('navTab$i'),
                                onTap: () => onTap(i),
                                child: Padding(
                                  padding: const EdgeInsets.only(top: 10),
                                  child: Column(
                                    mainAxisAlignment: MainAxisAlignment.start,
                                    children: [
                                      Icon(
                                        destination.icon,
                                        color: color,
                                        size: 21,
                                      ),
                                      const SizedBox(height: 4),
                                      AnimatedDefaultTextStyle(
                                        duration: const Duration(
                                          milliseconds: 200,
                                        ),
                                        style: TextStyle(
                                          fontSize: 10.5,
                                          color: color,
                                          fontWeight: selected
                                              ? FontWeight.w700
                                              : FontWeight.w500,
                                        ),
                                        child: Text(destination.label),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            );
                          }),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
