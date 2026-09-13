import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';

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
    return Container(
      decoration: const BoxDecoration(
        color: AppColors.bg,
        border: Border(top: BorderSide(color: AppColors.hairline)),
      ),
      child: SafeArea(
        top: false,
        // Fix the height *before* Align: Scaffold gives the
        // bottomNavigationBar slot a bounded-but-loose height, and an Align
        // (unlike a Center with a tightly-sized child) expands to fill any
        // bounded height it's given rather than shrink-wrapping its child —
        // without this SizedBox the whole bar (and its tap targets) would
        // stretch to fill the screen instead of staying a compact strip.
        child: SizedBox(
          height: 58,
          child: Align(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 640),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final itemWidth = constraints.maxWidth / _destinations.length;
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
    );
  }
}
