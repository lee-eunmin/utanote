import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';

/// A compact, wrap-capable segmented control: hairline-bordered rectangular
/// segments with a subtle tinted fill on the selected item, rather than a
/// large filled ChoiceChip pill.
class ChoiceChipRow<T> extends StatelessWidget {
  final List<T> options;
  final T? value;
  final ValueChanged<T> onChanged;
  final String Function(T option) labelBuilder;

  const ChoiceChipRow({
    super.key,
    required this.options,
    required this.value,
    required this.onChanged,
    required this.labelBuilder,
  });

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: options.map((option) {
        final selected = option == value;
        return GestureDetector(
          onTap: () => onChanged(option),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            curve: Curves.easeOut,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
            decoration: BoxDecoration(
              color: selected
                  ? AppColors.accent.withValues(alpha: 0.14)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(7),
              border: Border.all(
                color: selected ? AppColors.accent : AppColors.hairline,
                width: 1,
              ),
            ),
            child: Text(
              labelBuilder(option),
              style: TextStyle(
                fontSize: 13,
                color: selected
                    ? AppColors.textPrimary
                    : AppColors.textSecondary,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
              ),
            ),
          ),
        );
      }).toList(),
    );
  }
}
