/// Design tokens. Source of truth for spacing/radius/motion. Screens must not
/// invent their own.
library;

import 'package:material_ui/material_ui.dart';

/// 4px grid. Use these instead of literal EdgeInsets values in new code.
abstract final class AppSpace {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16; // page side padding
  static const double xl = 24; // between groups
  static const double titleToCard = 8;
}

abstract final class AppRadius {
  static const double chip = 8;
  static const double control = 12; // buttons, segmented pills' inner
  static const double input = 16;
  static const double card = 20;
  static const double sheet = 28;
}

abstract final class AppRow {
  static const double single = 52; // one-line list row
  static const double twoLine = 64; // two-line list row
}

abstract final class AppMotion {
  static const Duration fast = Duration(milliseconds: 120);
  static const Duration normal = Duration(milliseconds: 200);
  static const Duration slow = Duration(milliseconds: 300);
  static const Duration stagger = Duration(milliseconds: 30);
  static const Curve standard = Curves.easeOutCubic;
  static const double pressScale = 0.97;

  /// Returns [d] or Duration.zero when the OS asks to reduce motion.
  static Duration of(BuildContext context, Duration d) =>
      MediaQuery.disableAnimationsOf(context) ? Duration.zero : d;
}
