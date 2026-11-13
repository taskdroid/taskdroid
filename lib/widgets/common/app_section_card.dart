import 'package:flutter/material.dart';
import 'package:taskdroid/theme/tokens.dart';

/// A low-emphasis surface for a related group of controls or details.
class AppSectionCard extends StatelessWidget {
  const AppSectionCard({
    super.key,
    required this.child,
    this.padding = EdgeInsets.zero,
  });

  /// A card holding [rows] stacked vertically, separated by hairlines.
  factory AppSectionCard.rows(List<Widget> rows, {Key? key}) {
    return AppSectionCard(key: key, child: _AppSectionRows(rows));
  }

  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Container(
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: colorScheme.outline.withValues(alpha: 0.1)),
      ),
      child: Padding(padding: padding, child: child),
    );
  }
}

/// Stacks [rows] with a hairline between each pair.
class _AppSectionRows extends StatelessWidget {
  const _AppSectionRows(this.rows);

  final List<Widget> rows;

  @override
  Widget build(BuildContext context) {
    final divider = Divider(
      height: 1,
      thickness: 1,
      indent: AppSpace.lg,
      color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.1),
    );

    final children = <Widget>[];
    for (var i = 0; i < rows.length; i++) {
      if (i > 0) children.add(divider);
      children.add(rows[i]);
    }

    return Column(mainAxisSize: MainAxisSize.min, children: children);
  }
}
