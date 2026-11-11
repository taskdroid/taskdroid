import 'package:material_ui/material_ui.dart';
import 'package:taskdroid/theme/tokens.dart';

/// Tag editor used by the task editor's tag sheet: selected chips, a search
/// field and an inline suggestion list.
///
/// The suggestions are part of this widget rather than a floating autocomplete
/// overlay so they stay inside the sheet, above the keyboard, and scrolling
/// them keeps the keyboard open.
class TagInput extends StatefulWidget {
  final List<String> selectedTags;
  final Set<String> availableTags;
  final Function(List<String>) onChanged;

  const TagInput({
    super.key,
    required this.selectedTags,
    required this.availableTags,
    required this.onChanged,
  });

  @override
  State<TagInput> createState() => _TagInputState();
}

class _TagInputState extends State<TagInput> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focusNode = FocusNode();

  /// Caps the selected-chips block at roughly three rows so the suggestion
  /// list always keeps room; past that the chips scroll.
  static const double _chipsMaxHeight = 140;

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _addTag(String tag) {
    final cleanTag = tag.trim();
    if (cleanTag.isNotEmpty && !widget.selectedTags.contains(cleanTag)) {
      final newList = List<String>.from(widget.selectedTags)..add(cleanTag);
      widget.onChanged(newList);
    }
    _controller.clear();
    _focusNode.requestFocus();
    setState(() {});
  }

  void _removeTag(String tag) {
    final newList = List<String>.from(widget.selectedTags)..remove(tag);
    widget.onChanged(newList);
  }

  List<String> _suggestions() {
    final query = _controller.text.trim().toLowerCase();
    return widget.availableTags
        .where((tag) => !widget.selectedTags.contains(tag))
        .where((tag) => query.isEmpty || tag.toLowerCase().contains(query))
        .toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final suggestions = _suggestions();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.selectedTags.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpace.md),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: _chipsMaxHeight),
              child: SingleChildScrollView(
                child: Wrap(
                  spacing: AppSpace.sm,
                  runSpacing: AppSpace.sm,
                  children: widget.selectedTags.map((tag) {
                    return InputChip(
                      label: Text(
                        tag,
                        style: const TextStyle(fontWeight: FontWeight.w500),
                      ),
                      onDeleted: () => _removeTag(tag),
                      backgroundColor: colorScheme.secondaryContainer,
                      labelStyle: TextStyle(
                        color: colorScheme.onSecondaryContainer,
                      ),
                      deleteIconColor: colorScheme.onSecondaryContainer
                          .withValues(alpha: 0.7),
                      side: BorderSide.none,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(AppRadius.chip),
                      ),
                    );
                  }).toList(),
                ),
              ),
            ),
          ),
        TextField(
          controller: _controller,
          focusNode: _focusNode,
          autofocus: true,
          decoration: InputDecoration(
            hintText: 'Add a tag',
            prefixIcon: const Icon(Icons.local_offer_outlined),
            suffixIcon: IconButton(
              icon: const Icon(Icons.add_circle),
              color: colorScheme.primary,
              onPressed: () => _addTag(_controller.text),
            ),
          ),
          onChanged: (_) => setState(() {}),
          onSubmitted: _addTag,
        ),
        const SizedBox(height: AppSpace.sm),
        Expanded(
          child: suggestions.isEmpty
              ? Center(
                  child: Text(
                    widget.availableTags.isEmpty
                        ? 'No tags yet'
                        : 'No matching tags',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.only(bottom: AppSpace.lg),
                  itemCount: suggestions.length,
                  itemBuilder: (context, index) {
                    final tag = suggestions[index];
                    return InkWell(
                      onTap: () => _addTag(tag),
                      borderRadius: BorderRadius.circular(AppRadius.chip),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: AppSpace.sm,
                          vertical: AppSpace.md,
                        ),
                        child: Row(
                          children: [
                            Icon(
                              Icons.label_outline,
                              size: 16,
                              color: colorScheme.onSurfaceVariant,
                            ),
                            const SizedBox(width: AppSpace.md),
                            Expanded(
                              child: Text(
                                tag,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodyLarge?.copyWith(
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}
