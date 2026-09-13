import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';

class SelectionAction {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool destructive;

  const SelectionAction({
    required this.icon,
    required this.label,
    required this.onTap,
    this.destructive = false,
  });
}

/// A bottom action bar that grows in/out (~220ms) when a multi-select
/// session is active, shown docked at the bottom of a screen's body.
class SelectionActionBar extends StatelessWidget {
  final bool visible;
  final int count;
  final List<SelectionAction> actions;
  final VoidCallback onClose;

  const SelectionActionBar({
    super.key,
    required this.visible,
    required this.count,
    required this.actions,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedSize(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
      alignment: Alignment.bottomCenter,
      child: !visible
          ? const SizedBox(width: double.infinity)
          : Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: const BoxDecoration(
                color: AppColors.surfaceHigh,
                borderRadius: BorderRadius.vertical(top: Radius.circular(10)),
                border: Border(top: BorderSide(color: AppColors.hairline)),
              ),
              child: Row(
                children: [
                  IconButton(
                    onPressed: onClose,
                    icon: const Icon(
                      Icons.close_rounded,
                      color: AppColors.textSecondary,
                    ),
                  ),
                  Text(
                    '$count개 선택됨',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  const Spacer(),
                  for (final action in actions)
                    IconButton(
                      onPressed: action.onTap,
                      tooltip: action.label,
                      icon: Icon(
                        action.icon,
                        color: action.destructive
                            ? AppColors.danger
                            : AppColors.textPrimary,
                      ),
                    ),
                ],
              ),
            ),
    );
  }
}
