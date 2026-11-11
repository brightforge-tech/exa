import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// BrightForge design language: a calm slate canvas with a single living
/// teal accent and a forge-orange spark (brand colours from
/// brightforgett.com). Type pairing - Sora for display, Manrope for
/// everything else.
abstract class ExaColors {
  // Layered dark canvas (never pure black - keeps depth on OLED).
  static const bg = Color(0xFF0F1316);
  static const surfaceLow = Color(0xFF151B1F);
  static const surface = Color(0xFF1A2126);
  static const surfaceHigh = Color(0xFF212A30);
  static const surfaceHighest = Color(0xFF263036);
  static const outline = Color(0xFF33404A);

  // Text ramp.
  static const textPrimary = Color(0xFFF2EFE9);
  static const textSecondary = Color(0xFFAEB7BC);
  static const textTertiary = Color(0xFF6E7A80);

  // The one living accent - used surgically.
  static const accent = Color(0xFF35B2BE);
  static const accentGlowStart = Color(0xFF2A9AA6);
  static const accentGlowEnd = Color(0xFF5CC9D3);
  static const spark = Color(0xFFE07A45);
  static const accentContainer = Color(0xFF123A40);
  static const onAccentContainer = Color(0xFFC8EEF2);

  /// BrightForge forge orange - the logo band and the AI spark.
  static const forge = Color(0xFFC2551C);

  // Status, desaturated to live in the dark world.
  static const success = Color(0xFF49C98A);
  static const warning = Color(0xFFE0A458);
  static const error = Color(0xFFF26D6D);

  /// The signature gradient (Exa orb, key CTAs, accent strokes).
  static const accentGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [accentGlowStart, accentGlowEnd],
  );
}

/// Shared geometry.
abstract class ExaRadii {
  static const card = 20.0;
  static const chip = 12.0;
  static const field = 14.0;
  static const sheet = 28.0;
}

ThemeData buildExaDarkTheme() {
  const scheme = ColorScheme(
    brightness: Brightness.dark,
    primary: ExaColors.accent,
    // Teal is light: dark text on it reads far better than white.
    onPrimary: ExaColors.bg,
    primaryContainer: ExaColors.accentContainer,
    onPrimaryContainer: ExaColors.onAccentContainer,
    secondary: ExaColors.spark,
    onSecondary: Color(0xFF0F1316),
    secondaryContainer: Color(0xFF1E272C),
    onSecondaryContainer: ExaColors.textPrimary,
    tertiary: ExaColors.spark,
    onTertiary: Colors.white,
    error: ExaColors.error,
    onError: Color(0xFF2A0F0F),
    surface: ExaColors.bg,
    onSurface: ExaColors.textPrimary,
    onSurfaceVariant: ExaColors.textSecondary,
    surfaceContainerLowest: ExaColors.bg,
    surfaceContainerLow: ExaColors.surfaceLow,
    surfaceContainer: ExaColors.surface,
    surfaceContainerHigh: ExaColors.surfaceHigh,
    surfaceContainerHighest: ExaColors.surfaceHighest,
    outline: ExaColors.outline,
    outlineVariant: Color(0xFF202A30),
    scrim: Colors.black,
  );

  final base = ThemeData.dark(useMaterial3: true);

  // Body / UI: Manrope. Display / headlines: Sora.
  final body = GoogleFonts.manropeTextTheme(base.textTheme).apply(
    bodyColor: ExaColors.textPrimary,
    displayColor: ExaColors.textPrimary,
  );
  final textTheme = body.copyWith(
    displayLarge: GoogleFonts.sora(
        textStyle: body.displayLarge,
        fontWeight: FontWeight.w600,
        color: ExaColors.textPrimary),
    displayMedium: GoogleFonts.sora(
        textStyle: body.displayMedium,
        fontWeight: FontWeight.w600,
        color: ExaColors.textPrimary),
    displaySmall: GoogleFonts.sora(
        textStyle: body.displaySmall,
        fontWeight: FontWeight.w600,
        color: ExaColors.textPrimary),
    headlineLarge: GoogleFonts.sora(
        textStyle: body.headlineLarge,
        fontWeight: FontWeight.w600,
        color: ExaColors.textPrimary),
    headlineMedium: GoogleFonts.sora(
        textStyle: body.headlineMedium,
        fontWeight: FontWeight.w600,
        color: ExaColors.textPrimary),
    headlineSmall: GoogleFonts.sora(
        textStyle: body.headlineSmall,
        fontWeight: FontWeight.w600,
        color: ExaColors.textPrimary),
    titleLarge: GoogleFonts.sora(
        textStyle: body.titleLarge,
        fontWeight: FontWeight.w600,
        color: ExaColors.textPrimary),
  );

  return base.copyWith(
    colorScheme: scheme,
    scaffoldBackgroundColor: ExaColors.bg,
    textTheme: textTheme,
    splashFactory: InkSparkle.splashFactory,
    appBarTheme: AppBarTheme(
      backgroundColor: ExaColors.bg,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: textTheme.titleLarge,
      iconTheme: const IconThemeData(color: ExaColors.textSecondary),
    ),
    cardTheme: CardThemeData(
      color: ExaColors.surfaceHigh,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(ExaRadii.card),
        side: const BorderSide(color: ExaColors.outline, width: 1),
      ),
    ),
    dividerTheme: const DividerThemeData(
        color: ExaColors.outline, thickness: 1, space: 1),
    listTileTheme: const ListTileThemeData(
      iconColor: ExaColors.textSecondary,
      textColor: ExaColors.textPrimary,
      subtitleTextStyle:
          TextStyle(color: ExaColors.textSecondary, fontSize: 13),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: ExaColors.surfaceHighest,
      hintStyle: const TextStyle(color: ExaColors.textTertiary),
      contentPadding:
          const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(ExaRadii.field),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(ExaRadii.field),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(ExaRadii.field),
        borderSide: const BorderSide(color: ExaColors.accent, width: 1.5),
      ),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: ExaColors.surfaceHighest,
      side: const BorderSide(color: ExaColors.outline),
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(ExaRadii.chip)),
      labelStyle: const TextStyle(color: ExaColors.textSecondary),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: ExaColors.accent,
        foregroundColor: Colors.white,
        padding:
            const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(ExaRadii.field)),
        textStyle: const TextStyle(fontWeight: FontWeight.w600),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: ExaColors.spark),
    ),
    floatingActionButtonTheme: const FloatingActionButtonThemeData(
      backgroundColor: ExaColors.accent,
      foregroundColor: Colors.white,
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: ExaColors.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius:
            BorderRadius.vertical(top: Radius.circular(ExaRadii.sheet)),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: ExaColors.surfaceHigh,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(ExaRadii.card)),
    ),
    snackBarTheme: const SnackBarThemeData(
      backgroundColor: ExaColors.surfaceHighest,
      contentTextStyle: TextStyle(color: ExaColors.textPrimary),
      behavior: SnackBarBehavior.floating,
    ),
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: {
        TargetPlatform.android: FadeForwardsPageTransitionsBuilder(),
        TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
      },
    ),
  );
}
