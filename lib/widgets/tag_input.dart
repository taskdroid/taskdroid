import 'package:flutter/material.dart';

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
  }

  void _removeTag(String tag) {
    final newList = List<String>.from(widget.selectedTags)..remove(tag);
    widget.onChanged(newList);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (widget.selectedTags.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 12.0),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
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
                  deleteIconColor: colorScheme.onSecondaryContainer.withValues(
                    alpha: 0.7,
                  ),
                  side: BorderSide.none,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                );
              }).toList(),
            ),
          ),

        LayoutBuilder(
          builder: (context, constraints) {
            return RawAutocomplete<String>(
              textEditingController: _controller,
              focusNode: _focusNode,
              optionsBuilder: (TextEditingValue textEditingValue) {
                if (textEditingValue.text.isEmpty) {
                  return widget.availableTags.where(
                    (t) => !widget.selectedTags.contains(t),
                  );
                }
                return widget.availableTags.where((String option) {
                  return option.toLowerCase().contains(
                        textEditingValue.text.toLowerCase(),
                      ) &&
                      !widget.selectedTags.contains(option);
                });
              },
              onSelected: (String selection) {
                _addTag(selection);
              },
              fieldViewBuilder:
                  (context, fieldController, fieldFocusNode, onFieldSubmitted) {
                    return TextField(
                      controller: fieldController,
                      focusNode: fieldFocusNode,
                      decoration: InputDecoration(
                        labelText: 'Add Tag',
                        hintText: 'Type and press enter',
                        prefixIcon: const Icon(Icons.local_offer_outlined),
                        suffixIcon: IconButton(
                          icon: const Icon(Icons.add_circle),
                          color: colorScheme.primary,
                          onPressed: () => _addTag(fieldController.text),
                        ),
                      ),
                      onSubmitted: (value) => _addTag(value),
                    );
                  },
              optionsViewBuilder: (context, onSelected, options) {
                return Align(
                  alignment: Alignment.topLeft,
                  child: Material(
                    elevation: 4.0,
                    color: colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(16),
                    clipBehavior: Clip.antiAlias,
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        maxHeight: 220,
                        maxWidth: constraints.maxWidth,
                      ),
                      child: ListView.builder(
                        padding: EdgeInsets.zero,
                        shrinkWrap: true,
                        itemCount: options.length,
                        itemBuilder: (BuildContext context, int index) {
                          final String option = options.elementAt(index);
                          return InkWell(
                            onTap: () => onSelected(option),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16.0,
                                vertical: 14.0,
                              ),
                              child: Row(
                                children: [
                                  Icon(
                                    Icons.label_outline,
                                    size: 16,
                                    color: colorScheme.onSurfaceVariant,
                                  ),
                                  const SizedBox(width: 12),
                                  Text(
                                    option,
                                    style: TextStyle(
                                      color: colorScheme.onSurface,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                );
              },
            );
          },
        ),
      ],
    );
  }
}
