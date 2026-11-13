import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:taskdroid/theme/app_theme.dart';
import 'package:taskdroid/theme/tokens.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // google_fonts downloads Sora on first use, and reports a failed download as
  // an uncaught async error. Tests must not depend on the network, so runtime
  // fetching is disabled and the resulting load errors are ignored: the theme
  // object is still built exactly the same way, only without the font bytes.
  GoogleFonts.config.allowRuntimeFetching = false;

  late final ThemeData light;
  late final ThemeData dark;

  setUpAll(() async {
    await runZonedGuarded(
      () async {
        light = buildAppTheme(Brightness.light);
        dark = buildAppTheme(Brightness.dark);
        await Future<void>.delayed(const Duration(milliseconds: 20));
      },
      (error, stackTrace) {},
      zoneSpecification: ZoneSpecification(
        print: (self, parent, zone, line) {},
      ),
    );
  });

  test('buildAppTheme keeps the light and dark differences', () {
    expect(light.useMaterial3, isTrue);
    expect(light.appBarTheme.centerTitle, isTrue);
    expect(light.cardTheme.elevation, 0);
    expect(light.inputDecorationTheme.enabledBorder, isNotNull);

    expect(dark.useMaterial3, isTrue);
    expect(dark.appBarTheme.centerTitle, isTrue);
    expect(dark.cardTheme.elevation, 0);
    expect(dark.textTheme.bodyLarge?.color, Colors.white);
    expect(dark.inputDecorationTheme.enabledBorder, isNull);
  });

  test('buildAppTheme uses the radius tokens', () {
    for (final theme in [light, dark]) {
      final cardShape = theme.cardTheme.shape! as RoundedRectangleBorder;
      expect(cardShape.borderRadius, BorderRadius.circular(AppRadius.card));

      final sheetShape =
          theme.bottomSheetTheme.shape! as RoundedRectangleBorder;
      expect(
        sheetShape.borderRadius,
        const BorderRadius.vertical(top: Radius.circular(AppRadius.sheet)),
      );
    }
  });
}
