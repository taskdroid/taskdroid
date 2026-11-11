import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:taskdroid/theme/app_theme.dart';

/// Builds the app theme for tests.
///
/// google_fonts downloads Sora on first use and reports a failed download as an
/// uncaught async error. Tests must not depend on the network, so runtime
/// fetching is disabled and the resulting load errors are ignored: the theme
/// object is still built exactly the same way, only without the font bytes.
ThemeData testTheme([Brightness brightness = Brightness.light]) {
  GoogleFonts.config.allowRuntimeFetching = false;

  late final ThemeData theme;
  runZonedGuarded(
    () {
      theme = buildAppTheme(brightness);
    },
    (error, stackTrace) {},
    zoneSpecification: ZoneSpecification(print: (self, parent, zone, line) {}),
  );
  return theme;
}
