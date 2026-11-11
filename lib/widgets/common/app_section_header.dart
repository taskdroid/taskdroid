import 'package:material_ui/material_ui.dart';
import 'package:taskdroid/theme/tokens.dart';

/// A consistent heading for grouped content in settings and detail pages.
class AppSectionHeader extends StatelessWidget {
  const AppSectionHeader(
    this.title, {
    super.key,
    this.bottomPadding = AppSpace.md,
  });

  final String title;
  final double bottomPadding;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.only(left: AppSpace.xs, bottom: bottomPadding),
      child: Text(
        title.toUpperCase(),
        style: theme.textTheme.labelMedium?.copyWith(
          fontWeight: FontWeight.bold,
          letterSpacing: 1.2,
          color: theme.colorScheme.primary,
        ),
      ),
    );
  }
}
