import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taskdroid/theme/tokens.dart';

import 'test_theme.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late final ThemeData light;
  late final ThemeData dark;

  setUpAll(() {
    light = testTheme();
    dark = testTheme(Brightness.dark);
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
