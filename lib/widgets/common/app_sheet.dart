import 'package:flutter/material.dart';
import 'package:taskdroid/theme/tokens.dart';

/// Dismisses the keyboard when a tap lands on space no other widget claims.
///
/// Install this once, around the whole app (in `MaterialApp.builder`), so it
/// covers routes and the Navigator overlay, sheets included. Buttons, list
/// tiles and fields win the gesture arena; only unclaimed taps reach this.
/// `onTap` (not a pointer listener) so tapping another field does not blink the
/// keyboard. Sheets must not add a layer of their own.
class AppTapToDismiss extends StatelessWidget {
  const AppTapToDismiss({super.key, this.child});

  final Widget? child;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: () => FocusManager.instance.primaryFocus?.unfocus(),
      child: child,
    );
  }
}

/// The only way to open a bottom sheet in this app. Shape, drag handle,
/// clipping, safe area and keyboard avoidance come from the theme and this
/// helper; call sites supply content only.
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
      Widget content = SafeArea(top: false, child: builder(sheetContext));

      if (heightFactor != null) {
        content = FractionallySizedBox(
          heightFactor: heightFactor,
          child: content,
        );
      }

      // `showModalBottomSheet` anchors the sheet to the bottom of the screen and
      // ignores `viewInsets`, so lift it ourselves. Done outside the
      // `FractionallySizedBox` so a fractional sheet is a fraction of the space
      // the keyboard leaves over.
      return AnimatedPadding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(sheetContext).bottom,
        ),
        duration: AppMotion.of(sheetContext, AppMotion.normal),
        curve: AppMotion.standard,
        child: content,
      );
    },
  );
}

/// Action bar for form sheets: Cancel on the left, title centred, primary
/// action on the right. Replaces [AppSheetHeader] when the sheet has a confirm
/// action; list and menu sheets keep [AppSheetHeader].
class AppSheetActionBar extends StatelessWidget {
  const AppSheetActionBar({
    super.key,
    required this.title,
    required this.onCancel,
    required this.actionLabel,
    this.onAction,
    this.cancelLabel = 'Cancel',
  });

  final String title;
  final VoidCallback onCancel;
  final String actionLabel;

  /// `null` renders the action disabled.
  final VoidCallback? onAction;
  final String cancelLabel;

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
      child: SizedBox(
        height: 48,
        child: Row(
          children: [
            TextButton(
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: AppSpace.sm),
              ),
              onPressed: onCancel,
              child: Text(cancelLabel),
            ),
            // Fixed gutters so a title that fills the middle never sits flush
            // against either button on a narrow sheet.
            const SizedBox(width: AppSpace.sm),
            Expanded(
              child: Text(
                title,
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(width: AppSpace.sm),
            FilledButton(
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: AppSpace.md),
              ),
              onPressed: onAction,
              child: Text(actionLabel),
            ),
          ],
        ),
      ),
    );
  }
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
