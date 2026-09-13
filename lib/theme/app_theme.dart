import 'package:flutter/material.dart';

/// Central color palette and type scale for the dark, editorial UI.
///
/// Colors/styles here are purely visual (the UI layer). None of this affects
/// the underlying `songs`/`folders` schema or storage — see CLAUDE.md.
class AppColors {
  AppColors._();

  static const bg = Color(0xFF111113);
  static const surface = Color(0xFF111113);
  static const surfaceHigh = Color(0xFF1E1E22);
  static const surfacePressed = Color(0xFF26262B);
  static const accent = Color(0xFFCC9A4C);
  static const textPrimary = Color(0xFFF3F1ED);
  static const textSecondary = Color(0xFF9A99A1);
  static const textTertiary = Color(0xFF67666D);
  static const hairline = Color(0xFF28282C);
  static const danger = Color(0xFFD9635C);

  static const statusNotStarted = Color(0xFF57565D);
  static const statusPracticing = Color(0xFFCC9A4C);
  static const statusDone = Color(0xFF6FBE7A);

  static const difficultyEasy = Color(0xFF6FBE7A);
  static const difficultyMedium = Color(0xFFD8B15A);
  static const difficultyHard = Color(0xFFD9695F);

  static const favorite = Color(0xFFD9697D);
  static const male = Color(0xFF6E93CF);
  static const female = Color(0xFFCC7FA0);

  /// Curated, muted hues used to give each folder a distinct identity
  /// without resorting to gradients or bright/neon colors.
  static const folderAccents = [
    Color(0xFFCC9A4C),
    Color(0xFF6E93CF),
    Color(0xFFCC7FA0),
    Color(0xFF6FBE7A),
    Color(0xFF8E8CC7),
    Color(0xFFCC7A5C),
  ];
}

/// Reusable text styles for the app's editorial type hierarchy. Deliberately
/// built on the platform default font family (no bundled/network font) —
/// hierarchy comes from size, weight, and letter-spacing contrast instead.
class AppTextStyles {
  AppTextStyles._();

  static const brand = TextStyle(
    fontSize: 25,
    fontWeight: FontWeight.w800,
    letterSpacing: 0.8,
    height: 1.05,
    color: AppColors.textPrimary,
  );

  static const meta = TextStyle(
    fontSize: 12.5,
    fontWeight: FontWeight.w500,
    color: AppColors.textSecondary,
  );

  /// Small uppercase-feeling section/field label.
  static const label = TextStyle(
    fontSize: 11,
    fontWeight: FontWeight.w700,
    letterSpacing: 0.7,
    color: AppColors.textTertiary,
  );

  static const sheetTitle = TextStyle(
    fontSize: 17,
    fontWeight: FontWeight.w700,
    letterSpacing: 0.2,
    color: AppColors.textPrimary,
  );
}

/// Practice-status → accent color, used for the colored indicator on each
/// song card. Unknown/missing status falls back to the "not started" color.
Color practiceStatusColor(String? status) {
  switch (status) {
    case '완료':
      return AppColors.statusDone;
    case '연습 중':
      return AppColors.statusPracticing;
    case '연습 전':
    default:
      return AppColors.statusNotStarted;
  }
}

Color difficultyColor(String? difficulty) {
  switch (difficulty) {
    case '쉬움':
      return AppColors.difficultyEasy;
    case '보통':
      return AppColors.difficultyMedium;
    case '어려움':
      return AppColors.difficultyHard;
    default:
      return AppColors.textTertiary;
  }
}

/// Deterministic, stable-per-name accent so a given folder always renders
/// with the same subtle identity color.
Color folderAccentColor(String name) {
  if (name.isEmpty) return AppColors.folderAccents.first;
  final hash = name.codeUnits.fold<int>(0, (acc, c) => acc + c);
  return AppColors.folderAccents[hash % AppColors.folderAccents.length];
}

ThemeData buildAppTheme() {
  final base = ThemeData(brightness: Brightness.dark, useMaterial3: true);
  return base.copyWith(
    scaffoldBackgroundColor: AppColors.bg,
    colorScheme: base.colorScheme.copyWith(
      surface: AppColors.surface,
      primary: AppColors.accent,
      secondary: AppColors.accent,
      error: AppColors.danger,
    ),
    textTheme: base.textTheme.apply(
      bodyColor: AppColors.textPrimary,
      displayColor: AppColors.textPrimary,
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: AppColors.bg,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      foregroundColor: AppColors.textPrimary,
      centerTitle: false,
      titleTextStyle: AppTextStyles.sheetTitle,
    ),
    dividerColor: AppColors.hairline,
    cardTheme: CardThemeData(
      color: AppColors.surfaceHigh,
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: AppColors.surfaceHigh,
      hintStyle: const TextStyle(color: AppColors.textSecondary, fontSize: 14),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: AppColors.accent, width: 1.4),
      ),
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: AppColors.surfaceHigh,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: AppColors.surfaceHigh,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: AppColors.accent,
        foregroundColor: Colors.black,
        textStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
        padding: const EdgeInsets.symmetric(vertical: 13),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: AppColors.textPrimary,
        textStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
        side: const BorderSide(color: AppColors.hairline),
        padding: const EdgeInsets.symmetric(vertical: 13),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    ),
    splashFactory: InkRipple.splashFactory,
  );
}
