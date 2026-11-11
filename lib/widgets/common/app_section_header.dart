import 'package:flutter/material.dart';

/// A consistent heading for grouped content in settings and detail pages.
class AppSectionHeader extends StatelessWidget {
  const AppSectionHeader(this.title, {super.key, this.bottomPadding = 12});

  final String title;
  final double bottomPadding;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(left: 4, bottom: bottomPadding),
      child: Text(
        title.toUpperCase(),
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.bold,
          letterSpacing: 1.2,
          color: Theme.of(context).colorScheme.primary,
        ),
      ),
    );
  }
}
