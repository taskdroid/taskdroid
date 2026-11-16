import 'package:flutter/material.dart';
import 'package:taskdroid/theme/tokens.dart';

/// A compact, chip-shaped attribute editor: [icon] + [label] when unset,
/// [icon] + [value] on the primary container when set, plus a clear affordance
/// when [onClear] is given.
class AppAttributeChip extends StatelessWidget {
  const AppAttributeChip({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.value,
    this.onClear,
    this.expand = false,
    this.maxLines = 1,
  });

  final IconData icon;
  final String label;
  final String? value;
  final VoidCallback onTap;
  final VoidCallback? onClear;

  /// When true the chip fills the width it is given, with the text taking the
  /// slack, instead of hugging its content.
  final bool expand;

  /// How many lines the label or value may use before ellipsizing.
  final int maxLines;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isSet = value != null && value!.isNotEmpty;
    final foreground = isSet
        ? colorScheme.onPrimaryContainer
        : colorScheme.onSurfaceVariant;

    final text = Text(
      isSet ? value! : label,
      maxLines: maxLines,
      overflow: TextOverflow.ellipsis,
      style: theme.textTheme.labelLarge?.copyWith(color: foreground),
    );

    return _Pressable(
      onTap: onTap,
      child: Container(
        constraints: const BoxConstraints(minHeight: 36),
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpace.md,
          vertical: AppSpace.sm,
        ),
        decoration: BoxDecoration(
          color: isSet ? colorScheme.primaryContainer : Colors.transparent,
          borderRadius: BorderRadius.circular(AppRadius.chip),
          border: Border.all(
            color: isSet
                ? Colors.transparent
                : colorScheme.outline.withValues(alpha: 0.3),
          ),
        ),
        child: Row(
          mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: foreground),
            const SizedBox(width: AppSpace.sm),
            if (expand) Expanded(child: text) else Flexible(child: text),
            if (isSet && onClear != null) ...[
              const SizedBox(width: AppSpace.xs),
              GestureDetector(
                onTap: onClear,
                behavior: HitTestBehavior.opaque,
                child: Icon(Icons.close, size: 16, color: foreground),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Tap feedback: scales down to [AppMotion.pressScale] while pressed.
///
/// Private for now; lift it into `lib/widgets/common/` when a second caller
/// needs the same behaviour.
class _Pressable extends StatefulWidget {
  const _Pressable({required this.child, required this.onTap});

  final Widget child;
  final VoidCallback onTap;

  @override
  State<_Pressable> createState() => _PressableState();
}

class _PressableState extends State<_Pressable> {
  bool _pressed = false;

  void _setPressed(bool pressed) {
    if (_pressed == pressed) return;
    setState(() => _pressed = pressed);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onTap,
      onTapDown: (_) => _setPressed(true),
      onTapUp: (_) => _setPressed(false),
      onTapCancel: () => _setPressed(false),
      child: AnimatedScale(
        scale: _pressed ? AppMotion.pressScale : 1,
        duration: AppMotion.of(context, AppMotion.fast),
        curve: AppMotion.standard,
        child: widget.child,
      ),
    );
  }
}
