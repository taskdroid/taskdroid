import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:taskdroid/theme/tokens.dart';

/// Builds the app theme for [brightness].
///
/// Light and dark differ in exactly three places: the text colours, the
/// default input border, and the card border.
ThemeData buildAppTheme(Brightness brightness) {
  final isDark = brightness == Brightness.dark;
  final colorScheme = ColorScheme.fromSeed(
    seedColor: const Color(0xFF4F46E5),
    brightness: brightness,
  );
  final baseTextTheme = GoogleFonts.soraTextTheme();
  final textTheme = isDark
      ? baseTextTheme.apply(bodyColor: Colors.white, displayColor: Colors.white)
      : baseTextTheme;

  // Sheets, dialogs-adjacent surfaces and the drawer share one surface. The
  // Material 3 sheet default is the tinted `surfaceContainerLow`; the drawer
  // header already uses that tint, so sheets and the drawer body stay on the
  // plain page surface they were designed against. Decided here once, so no
  // call site sets a colour.
  final sheetSurface = colorScheme.surface;

  return ThemeData(
    useMaterial3: true,
    colorScheme: colorScheme,
    textTheme: textTheme,
    appBarTheme: const AppBarTheme(
      centerTitle: true,
      elevation: 0,
      scrolledUnderElevation: 0,
      backgroundColor: Colors.transparent,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
      contentPadding: const EdgeInsets.symmetric(
        horizontal: AppSpace.lg,
        vertical: AppSpace.lg,
      ),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.input),
        borderSide: isDark
            ? BorderSide.none
            : BorderSide(color: colorScheme.outlineVariant),
      ),
      enabledBorder: isDark
          ? null
          : OutlineInputBorder(
              borderRadius: BorderRadius.circular(AppRadius.input),
              borderSide: BorderSide(color: colorScheme.outlineVariant),
            ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.input),
        borderSide: BorderSide(color: colorScheme.primary, width: 2),
      ),
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      color: colorScheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.card),
        side: BorderSide(
          color: isDark
              ? colorScheme.outlineVariant.withValues(alpha: 0.3)
              : colorScheme.outlineVariant,
        ),
      ),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: sheetSurface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(AppRadius.sheet),
        ),
      ),
      showDragHandle: true,
      clipBehavior: Clip.antiAlias,
    ),
    drawerTheme: DrawerThemeData(backgroundColor: sheetSurface),
    dialogTheme: DialogThemeData(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.sheet),
      ),
    ),
    chipTheme: ChipThemeData(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.chip),
      ),
    ),
  );
}
