import 'package:material_ui/material_ui.dart';
import 'package:taskdroid/theme/tokens.dart';

/// A label/value row meant to be stacked inside an `AppSectionCard`.
///
/// Without a [value] the row shows [placeholder] in a muted colour and a
/// chevron; with one it shows the value and, when [onClear] is given, a clear
/// button instead of the chevron.
class AppValueRow extends StatelessWidget {
  const AppValueRow({
    super.key,
    required this.label,
    this.icon,
    this.value,
    this.placeholder = 'Not set',
    this.onTap,
    this.onClear,
    this.trailing,
  });

  final IconData? icon;
  final String label;
  final String? value;
  final String placeholder;
  final VoidCallback? onTap;
  final VoidCallback? onClear;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final hasValue = value != null && value!.isNotEmpty;

    return InkWell(
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: AppRow.single),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpace.lg),
          child: Row(
            children: [
              if (icon != null) ...[
                Icon(icon, size: 20, color: colorScheme.onSurfaceVariant),
                const SizedBox(width: AppSpace.md),
              ],
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyLarge,
                ),
              ),
              // A row with a custom trailing widget and no value is a plain
              // labelled row, so it shows no placeholder.
              if (hasValue || trailing == null) ...[
                const SizedBox(width: AppSpace.md),
                Flexible(
                  child: Text(
                    hasValue ? value! : placeholder,
                    textAlign: TextAlign.right,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyLarge?.copyWith(
                      color: hasValue ? null : colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
              if (trailing != null)
                trailing!
              else if (hasValue && onClear != null)
                IconButton(
                  onPressed: onClear,
                  icon: const Icon(Icons.close, size: 18),
                  tooltip: 'Clear',
                  visualDensity: VisualDensity.compact,
                  constraints: const BoxConstraints(),
                  padding: const EdgeInsets.all(AppSpace.xs),
                )
              else
                Icon(
                  Icons.chevron_right,
                  size: 20,
                  color: colorScheme.onSurfaceVariant,
                ),
            ],
          ),
        ),
      ),
    );
  }
}
