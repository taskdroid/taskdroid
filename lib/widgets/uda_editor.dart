import 'package:material_ui/material_ui.dart';
import 'package:taskdroid/src/rust/api.dart';

class UdaEditor extends StatefulWidget {
  final List<UdaPair> initialUdas;
  final Function(List<UdaPair>) onChanged;

  const UdaEditor({
    super.key,
    required this.initialUdas,
    required this.onChanged,
  });

  @override
  State<UdaEditor> createState() => _UdaEditorState();
}

class _UdaEditorState extends State<UdaEditor> {
  late List<UdaRowModel> _rows;

  @override
  void initState() {
    super.initState();
    _rows = widget.initialUdas
        .map(
          (u) => UdaRowModel(
            keyController: TextEditingController(text: u.key),
            valueController: TextEditingController(text: u.value),
          ),
        )
        .toList();
  }

  @override
  void dispose() {
    for (var row in _rows) {
      row.dispose();
    }
    super.dispose();
  }

  void _notifyChanged() {
    final pairs = _rows
        .where((r) => r.keyController.text.trim().isNotEmpty)
        .map(
          (r) => UdaPair(
            key: r.keyController.text.trim(),
            value: r.valueController.text.trim(),
          ),
        )
        .toList();

    // deduplicate by key (last occurrence wins)
    final deduped = <String, UdaPair>{};
    for (final pair in pairs) {
      deduped[pair.key] = pair;
    }

    widget.onChanged(deduped.values.toList());
  }

  void _addRow() {
    final newRow = UdaRowModel(
      keyController: TextEditingController(),
      valueController: TextEditingController(),
    );
    setState(() {
      _rows.add(newRow);
    });

    // auto-focus after build
    WidgetsBinding.instance.addPostFrameCallback((_) {
      FocusScope.of(context).requestFocus(FocusNode());
    });
  }

  void _removeRow(int index) {
    setState(() {
      _rows[index].dispose();
      _rows.removeAt(index);
    });
    _notifyChanged();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              'Custom Attributes',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
                color: colorScheme.primary,
              ),
            ),
            ElevatedButton.icon(
              onPressed: _addRow,
              icon: const Icon(Icons.add_circle_outline, size: 18),
              label: const Text('Add Attribute'),
              style: ElevatedButton.styleFrom(
                elevation: 0,
                backgroundColor: colorScheme.secondaryContainer,
                foregroundColor: colorScheme.onSecondaryContainer,
                visualDensity: VisualDensity.compact,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),

        if (_rows.isEmpty)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 24),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: colorScheme.outline.withValues(alpha: 0.1),
              ),
            ),
            child: Column(
              children: [
                Icon(
                  Icons.extension_off_outlined,
                  color: colorScheme.outline,
                  size: 32,
                ),
                const SizedBox(height: 8),
                Text(
                  'No custom attributes defined',
                  style: TextStyle(
                    color: colorScheme.onSurfaceVariant,
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),

        ..._rows.asMap().entries.map((entry) {
          final index = entry.key;
          final row = entry.value;

          return Padding(
            padding: const EdgeInsets.only(bottom: 8.0),
            child: Container(
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                color: colorScheme.surfaceContainerHighest.withValues(
                  alpha: 0.4,
                ),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: colorScheme.outline.withValues(alpha: 0.1),
                ),
              ),
              child: Row(
                children: [
                  // Key Input
                  Expanded(
                    flex: 2,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: TextField(
                        controller: row.keyController,
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 14,
                        ),
                        decoration: const InputDecoration(
                          hintText: 'Key',
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          focusedBorder: InputBorder.none,
                          isDense: true,
                        ),
                        onChanged: (_) => _notifyChanged(),
                      ),
                    ),
                  ),

                  // Divider
                  Container(
                    height: 24,
                    width: 1,
                    color: colorScheme.outline.withValues(alpha: 0.2),
                  ),

                  // Value Input
                  Expanded(
                    flex: 3,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: TextField(
                        controller: row.valueController,
                        style: const TextStyle(fontSize: 14),
                        decoration: const InputDecoration(
                          hintText: 'Value',
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          focusedBorder: InputBorder.none,
                          isDense: true,
                        ),
                        onChanged: (_) => _notifyChanged(),
                      ),
                    ),
                  ),

                  // Delete Button
                  IconButton(
                    icon: Icon(
                      Icons.delete_outline,
                      color: colorScheme.error,
                      size: 20,
                    ),
                    onPressed: () => _removeRow(index),
                    visualDensity: VisualDensity.compact,
                  ),
                ],
              ),
            ),
          );
        }),
      ],
    );
  }
}

class UdaRowModel {
  final TextEditingController keyController;
  final TextEditingController valueController;

  UdaRowModel({required this.keyController, required this.valueController});

  void dispose() {
    keyController.dispose();
    valueController.dispose();
  }
}
