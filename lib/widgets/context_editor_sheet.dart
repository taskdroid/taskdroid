import 'package:material_ui/material_ui.dart';
import 'package:taskdroid/theme/tokens.dart';
import 'package:taskdroid/widgets/common/app_sheet.dart';

/// Defines a new context, or edits an existing one when initial values are
/// given. Pops with `{'name', 'query', 'write'}`.
class ContextEditorSheet extends StatefulWidget {
  const ContextEditorSheet({
    super.key,
    this.initialName,
    this.initialQuery,
    this.initialWrite,
  });

  final String? initialName;
  final String? initialQuery;
  final String? initialWrite;

  @override
  State<ContextEditorSheet> createState() => _ContextEditorSheetState();
}

class _ContextEditorSheetState extends State<ContextEditorSheet> {
  late final TextEditingController _nameController;
  late final TextEditingController _queryController;
  late final TextEditingController _writeController;

  bool get _isEditing => widget.initialName != null;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.initialName ?? '');
    _queryController = TextEditingController(text: widget.initialQuery ?? '');
    _writeController = TextEditingController(text: widget.initialWrite ?? '');
    if (_isEditing) {
      _nameController.selection = TextSelection(
        baseOffset: 0,
        extentOffset: _nameController.text.length,
      );
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _queryController.dispose();
    _writeController.dispose();
    super.dispose();
  }

  void _save() {
    final name = _nameController.text.trim();
    if (name.isEmpty) return;
    Navigator.pop(context, {
      'name': name,
      'query': _queryController.text.trim(),
      'write': _writeController.text.trim(),
    });
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ValueListenableBuilder<TextEditingValue>(
          valueListenable: _nameController,
          builder: (context, value, _) => AppSheetActionBar(
            title: _isEditing ? 'Edit Context' : 'Define Context',
            onCancel: () => Navigator.pop(context),
            actionLabel: 'Save',
            onAction: value.text.trim().isEmpty ? null : _save,
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpace.lg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: _nameController,
                autofocus: true,
                decoration: const InputDecoration(
                  hintText: 'e.g. work, home, study...',
                  prefixIcon: Icon(Icons.label_outline),
                ),
                textCapitalization: TextCapitalization.words,
              ),
              const SizedBox(height: AppSpace.md),
              TextField(
                controller: _queryController,
                decoration: const InputDecoration(
                  hintText: 'Read filter, e.g. +work or +freelance',
                  prefixIcon: Icon(Icons.filter_alt_outlined),
                ),
              ),
              const SizedBox(height: AppSpace.md),
              TextField(
                controller: _writeController,
                decoration: const InputDecoration(
                  hintText: 'Write default, e.g. +work project:Work',
                  prefixIcon: Icon(Icons.edit_outlined),
                ),
              ),
              const SizedBox(height: AppSpace.lg),
            ],
          ),
        ),
      ],
    );
  }
}
