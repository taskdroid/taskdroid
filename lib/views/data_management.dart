import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:taskdroid/providers/task_state.dart';
import 'package:taskdroid/services/backup_file_io.dart';
import 'package:taskdroid/widgets/app_drawer.dart';

class DataManagementPage extends StatefulWidget {
  const DataManagementPage({super.key});

  @override
  State<DataManagementPage> createState() => _DataManagementPageState();
}

class _DataManagementPageState extends State<DataManagementPage>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final TextEditingController _importController = TextEditingController();
  bool _includeDeleted = false;
  String? _exportResult;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    _importController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Data Management',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        bottom: TabBar(
          controller: _tabController,
          indicatorSize: TabBarIndicatorSize.tab,
          dividerColor: Colors.transparent,
          tabs: const [
            Tab(text: 'Export', icon: Icon(Icons.upload_rounded)),
            Tab(text: 'Import', icon: Icon(Icons.download_rounded)),
          ],
        ),
      ),
      drawer: const AppDrawer(currentRoute: '/data'),
      body: Consumer<TaskState>(
        builder: (context, taskState, _) {
          return TabBarView(
            controller: _tabController,
            children: [
              _buildExportTab(context, taskState, theme),
              _buildImportTab(context, taskState, theme),
            ],
          );
        },
      ),
    );
  }

  Widget _buildExportTab(
    BuildContext context,
    TaskState taskState,
    ThemeData theme,
  ) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 40),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildSectionHeader(context, 'Backup & Export'),
          Text(
            'Generate a JSON backup of your tasks. This file can be used to migrate your data to another device or profile.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 24),

          _buildGroupContainer(
            context,
            child: SwitchListTile(
              title: const Text(
                'Include History',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              subtitle: const Text('Export completed and deleted tasks'),
              value: _includeDeleted,
              onChanged: (val) {
                setState(() {
                  _includeDeleted = val;
                  _exportResult = null;
                });
              },
            ),
          ),

          const SizedBox(height: 24),
          SizedBox(
            width: double.infinity,
            height: 54,
            child: FilledButton.icon(
              onPressed: taskState.isLoading
                  ? null
                  : () => _performExport(context, taskState),
              icon: taskState.isLoading
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.analytics_outlined),
              label: Text(
                taskState.isLoading ? 'Processing...' : 'Generate Backup JSON',
              ),
            ),
          ),

          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            height: 54,
            child: FilledButton.tonalIcon(
              onPressed: taskState.isLoading
                  ? null
                  : () => _performExportToFile(context, taskState),
              icon: const Icon(Icons.save_alt_rounded),
              label: Text(
                taskState.isLoading ? 'Processing...' : 'Save Backup to File',
              ),
            ),
          ),

          if (_exportResult != null) ...[
            const SizedBox(height: 32),
            _buildSectionHeader(context, 'Export Result'),
            const SizedBox(height: 8),
            _buildCodePreview(context, _exportResult!),
          ],
        ],
      ),
    );
  }

  Widget _buildCodePreview(BuildContext context, String code) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Container(
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: colorScheme.outline.withValues(alpha: 0.2)),
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'TASKS_BACKUP.JSON',
                  style: theme.textTheme.labelSmall?.copyWith(
                    letterSpacing: 1.1,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                IconButton.filledTonal(
                  icon: const Icon(Icons.copy_rounded, size: 18),
                  visualDensity: VisualDensity.compact,
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: code));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Copied to clipboard')),
                    );
                  },
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Container(
            height: 250,
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            child: SingleChildScrollView(
              child: SelectableText(
                code,
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 12,
                  height: 1.5,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildImportTab(
    BuildContext context,
    TaskState taskState,
    ThemeData theme,
  ) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 40),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildSectionHeader(context, 'Restore & Import'),
          Text(
            'Paste a JSON backup to restore your tasks. Existing tasks with matching IDs will be updated.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 24),

          _buildGroupContainer(
            context,
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                TextField(
                  controller: _importController,
                  maxLines: 8,
                  decoration: InputDecoration(
                    hintText: '[{"uuid": "...", "description": "..."}]',
                    hintStyle: TextStyle(
                      color: theme.colorScheme.onSurfaceVariant.withValues(
                        alpha: 0.5,
                      ),
                    ),
                    alignLabelWithHint: true,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: () async {
                      try {
                        final json = await pickBackupFile();
                        if (!mounted || json == null) return;
                        _importController.text = json;
                      } on Exception {
                        if (!context.mounted) return;
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('Failed to read the selected file'),
                          ),
                        );
                      }
                    },
                    icon: const Icon(Icons.folder_open_rounded),
                    label: const Text('Pick JSON File'),
                  ),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: () async {
                      final data = await Clipboard.getData(
                        Clipboard.kTextPlain,
                      );
                      if (data?.text != null) {
                        _importController.text = data!.text!;
                      }
                    },
                    icon: const Icon(Icons.paste_rounded),
                    label: const Text('Paste from Clipboard'),
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 24),
          SizedBox(
            width: double.infinity,
            height: 54,
            child: FilledButton.icon(
              onPressed: taskState.isLoading
                  ? null
                  : () => _performImport(context, taskState),
              icon: const Icon(Icons.publish_rounded),
              label: Text(
                taskState.isLoading ? 'Importing...' : 'Start Import',
              ),
              style: FilledButton.styleFrom(
                backgroundColor: theme.colorScheme.tertiary,
                foregroundColor: theme.colorScheme.onTertiary,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _performExport(BuildContext context, TaskState taskState) async {
    final result = await _generateExport(context, taskState);
    if (!mounted || result == null) return;
    setState(() => _exportResult = result);
  }

  Future<void> _performExportToFile(
    BuildContext context,
    TaskState taskState,
  ) async {
    final result = await _generateExport(context, taskState);
    if (!mounted || result == null) return;

    final now = DateTime.now();
    final date =
        '${now.year}-'
        '${now.month.toString().padLeft(2, '0')}-'
        '${now.day.toString().padLeft(2, '0')}';

    final saved = await saveBackupFile(
      result,
      suggestedName: 'taskdroid-backup-$date.json',
    );
    if (!context.mounted) return;

    final message = switch (saved) {
      true => 'Backup saved to file',
      false => 'Failed to save backup',
      null => 'Save cancelled',
    };
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: switch (saved) {
          true => Colors.green,
          false => Colors.red,
          null => null,
        },
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Future<String?> _generateExport(
    BuildContext context,
    TaskState taskState,
  ) async {
    final count = await taskState.getTotalTaskCount();
    if (!context.mounted) return null;

    if (count > 500) {
      final confirm = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Large Data Set'),
          content: Text(
            'You are about to export $count tasks. This may take a moment.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Continue'),
            ),
          ],
        ),
      );
      if (confirm != true) return null;
    }

    if (!context.mounted) return null;

    final snackBar = ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Row(
          children: [
            SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            SizedBox(width: 12),
            Text('Generating export...'),
          ],
        ),
        duration: Duration(seconds: 30),
      ),
    );

    try {
      return await taskState.exportData(includeDeleted: _includeDeleted);
    } finally {
      snackBar.close();
    }
  }

  Future<void> _performImport(BuildContext context, TaskState taskState) async {
    final json = _importController.text.trim();
    if (json.isEmpty) return;

    final theme = Theme.of(context); // Define theme here

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Confirm Import'),
        content: const Text(
          'This will merge these tasks into your current profile. This action can only be reverted using "Undo" if available.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(
              backgroundColor: theme.colorScheme.tertiary,
              foregroundColor: theme.colorScheme.onTertiary,
            ),
            child: const Text('Import'),
          ),
        ],
      ),
    );

    if (confirm != true || !context.mounted) return;

    final error = await taskState.importData(json);
    if (!context.mounted) return;

    if (error == null) {
      _importController.clear();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Import successful!'),
          backgroundColor: Colors.green,
          behavior: SnackBarBehavior.floating,
        ),
      );
    } else {
      _showErrorDialog(context, error);
    }
  }

  void _showErrorDialog(BuildContext context, String message) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Import Failed'),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionHeader(BuildContext context, String title) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 12),
      child: Text(
        title.toUpperCase(),
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.bold,
          letterSpacing: 1.2,
          color: Theme.of(context).colorScheme.primary,
        ),
      ),
    );
  }

  Widget _buildGroupContainer(
    BuildContext context, {
    required Widget child,
    EdgeInsetsGeometry? padding,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(
          context,
        ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
          color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.1),
        ),
      ),
      child: Padding(padding: padding ?? EdgeInsets.zero, child: child),
    );
  }
}
