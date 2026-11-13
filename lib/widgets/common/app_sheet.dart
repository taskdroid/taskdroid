import 'package:flutter/material.dart';
import 'package:taskdroid/theme/tokens.dart';

/// The only way to open a bottom sheet in this app. Shape, drag handle,
/// clipping and safe area come from the theme and this helper; call sites
/// supply content only.
Future<T?> showAppSheet<T>(
  BuildContext context, {
  required WidgetBuilder builder,
  bool scrollControlled = false,
  double? heightFactor,
}) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: scrollControlled,
    useSafeArea: true,
    builder: (sheetContext) {
      final content = SafeArea(top: false, child: builder(sheetContext));
      if (heightFactor == null) return content;
      return FractionallySizedBox(heightFactor: heightFactor, child: content);
    },
  );
}

/// Title row at the top of a sheet, under the theme's drag handle.
class AppSheetHeader extends StatelessWidget {
  const AppSheetHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.trailing,
  });

  final String title;
  final String? subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpace.lg,
        0,
        AppSpace.lg,
        AppSpace.sm,
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: AppSpace.xs),
                  Text(
                    subtitle!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}
