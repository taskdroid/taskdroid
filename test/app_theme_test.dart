import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taskdroid/theme/app_theme.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('buildAppTheme keeps the light and dark differences', () {
    final light = buildAppTheme(Brightness.light);
    expect(light.useMaterial3, isTrue);
    expect(light.appBarTheme.centerTitle, isTrue);
    expect(light.cardTheme.elevation, 0);
    expect(light.inputDecorationTheme.enabledBorder, isNotNull);

    final dark = buildAppTheme(Brightness.dark);
    expect(dark.useMaterial3, isTrue);
    expect(dark.appBarTheme.centerTitle, isTrue);
    expect(dark.cardTheme.elevation, 0);
    expect(dark.textTheme.bodyLarge?.color, Colors.white);
    expect(dark.inputDecorationTheme.enabledBorder, isNull);
  });
}
