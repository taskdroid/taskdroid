import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:taskdroid/providers/profile_state.dart';
import 'package:taskdroid/providers/task_state.dart';
import 'package:taskdroid/src/rust/api.dart';
import 'package:taskdroid/widgets/task_editor.dart';

enum SeriesScope { single, entire }

class TaskDetailPage extends StatelessWidget {
  final String taskUuid;

  const TaskDetailPage({super.key, required this.taskUuid});

  @override
  Widget build(BuildContext context) {
    return Consumer<TaskState>(
      builder: (context, taskState, _) {
        final task = taskState.findTaskByUuid(taskUuid);
        if (task != null) {
          return _TaskDetailContent(task: task);
        } else {
          final theme = Theme.of(context);
          final colorScheme = theme.colorScheme;

          return Scaffold(
            appBar: AppBar(),
            body: Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(24),
                      decoration: BoxDecoration(
                        color: colorScheme.errorContainer.withValues(
                          alpha: 0.5,
                        ),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        Icons.error_outline,
                        size: 64,
                        color: colorScheme.error,
                      ),
                    ),
                    const SizedBox(height: 24),
                    Text(
                      'Task not found',
                      style: theme.textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'This task may have been deleted, completed, or removed during sync.',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 32),
                    ElevatedButton(
                      onPressed: () => Navigator.of(context).pop(),
                      style: ElevatedButton.styleFrom(
                        elevation: 0,
                        backgroundColor: colorScheme.secondaryContainer,
                        foregroundColor: colorScheme.onSecondaryContainer,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 32,
                          vertical: 16,
                        ),
                      ),
                      child: const Text('Go Back'),
                    ),
                  ],
                ),
              ),
            ),
          );
        }
      },
    );
  }
}

class _TaskDetailContent extends StatelessWidget {
  final TaskView task;

  const _TaskDetailContent({required this.task});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isStarted = task.isActive;

    final profileState = context.watch<ProfileState>();
    final isCalendarSyncEnabled =
        profileState.currentProfile?.calendarSync ?? false;
    final hasDueDate = task.due != null;

    String duration = '60';
    try {
      final u = task.udas.firstWhere((x) => x.key == 'duration');
      if (u.value.isNotEmpty) duration = u.value;
    } catch (_) {}

    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Task Details',
          style: TextStyle(fontWeight: FontWeight.w600),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.edit_outlined),
            tooltip: 'Edit Task',
            onPressed: () => _showEditDialog(context),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 60),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildHeaderCard(context, colorScheme, isStarted),
            const SizedBox(height: 16),

            _buildActionRow(context, colorScheme, isStarted),
            const SizedBox(height: 24),

            if (isCalendarSyncEnabled && hasDueDate)
              Container(
                margin: const EdgeInsets.only(bottom: 24),
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 16,
                ),
                decoration: BoxDecoration(
                  color: colorScheme.tertiaryContainer.withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: colorScheme.tertiary.withValues(alpha: 0.2),
                  ),
                ),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: colorScheme.tertiary.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Icon(
                        Icons.event_available,
                        color: colorScheme.tertiary,
                        size: 24,
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            "Synced to System Calendar",
                            style: TextStyle(
                              color: colorScheme.onTertiaryContainer,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            "Duration: $duration mins",
                            style: TextStyle(
                              color: colorScheme.onTertiaryContainer.withValues(
                                alpha: 0.8,
                              ),
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),

            _buildSectionHeader(context, 'Dates & Timeline'),
            _buildDatesCard(context, colorScheme),
            const SizedBox(height: 24),

            _buildSectionHeader(context, 'Properties & Relations'),
            _buildRelationsCard(context, colorScheme),
            const SizedBox(height: 24),

            if (task.udas.isNotEmpty) ...[
              _buildUdaTile(context, colorScheme),
              const SizedBox(height: 24),
            ],

            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                _buildSectionHeader(context, 'Notes', bottomPadding: 0),
                TextButton.icon(
                  onPressed: () => _showAddNoteDialog(context),
                  icon: const Icon(Icons.add_comment_outlined, size: 18),
                  label: const Text('Add Note'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            _buildAnnotationsList(context, colorScheme),
          ],
        ),
      ),
    );
  }

  Widget _buildHeaderCard(
    BuildContext context,
    ColorScheme colorScheme,
    bool isStarted,
  ) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: isStarted
            ? colorScheme.primaryContainer
            : colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(24),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (isStarted)
            Container(
              margin: const EdgeInsets.only(bottom: 12),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: colorScheme.primary,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                "ACTIVE",
                style: TextStyle(
                  color: colorScheme.onPrimary,
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.2,
                ),
              ),
            ),
          Text(
            task.description,
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.bold,
              color: isStarted
                  ? colorScheme.onPrimaryContainer
                  : colorScheme.onSurface,
              height: 1.3,
            ),
          ),
          if (task.project != null) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                Icon(
                  Icons.folder_outlined,
                  size: 18,
                  color: isStarted
                      ? colorScheme.onPrimaryContainer.withValues(alpha: 0.8)
                      : colorScheme.primary,
                ),
                const SizedBox(width: 6),
                Text(
                  task.project!,
                  style: TextStyle(
                    color: isStarted
                        ? colorScheme.onPrimaryContainer.withValues(alpha: 0.8)
                        : colorScheme.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildActionRow(
    BuildContext context,
    ColorScheme colorScheme,
    bool isStarted,
  ) {
    return Row(
      children: [
        Expanded(
          flex: 4,
          child: ElevatedButton.icon(
            onPressed: () {
              HapticFeedback.lightImpact();
              _toggleStart(context);
            },
            style: ElevatedButton.styleFrom(
              elevation: 0,
              backgroundColor: isStarted
                  ? colorScheme.tertiary
                  : colorScheme.primary,
              foregroundColor: isStarted
                  ? colorScheme.onTertiary
                  : colorScheme.onPrimary,
              padding: const EdgeInsets.symmetric(vertical: 16),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
            ),
            icon: Icon(
              isStarted ? Icons.pause_circle_filled : Icons.play_circle_fill,
            ),
            label: Text(
              isStarted ? 'Pause Task' : 'Start Task',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          flex: 3,
          child: ElevatedButton.icon(
            onPressed: () {
              HapticFeedback.lightImpact();
              _markDone(context);
            },
            style: ElevatedButton.styleFrom(
              elevation: 0,
              backgroundColor: colorScheme.secondaryContainer,
              foregroundColor: colorScheme.onSecondaryContainer,
              padding: const EdgeInsets.symmetric(vertical: 16),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
            ),
            icon: const Icon(Icons.check),
            label: const Text(
              'Done',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
        ),
        const SizedBox(width: 8),
        IconButton(
          onPressed: () {
            HapticFeedback.lightImpact();
            _deleteTask(context);
          },
          style: IconButton.styleFrom(
            backgroundColor: colorScheme.errorContainer.withValues(alpha: 0.5),
            foregroundColor: colorScheme.error,
            padding: const EdgeInsets.all(16),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
          ),
          icon: const Icon(Icons.delete_outline),
          tooltip: 'Delete',
        ),
      ],
    );
  }

  Widget _buildDatesCard(BuildContext context, ColorScheme colorScheme) {
    final rows = <Widget>[];

    if (task.due != null) {
      rows.add(
        _buildDetailRow(
          context,
          Icons.event,
          'Due',
          _formatDate(task.due!),
          colorScheme.error,
        ),
      );
    }
    if (task.wait != null) {
      rows.add(
        _buildDetailRow(
          context,
          Icons.hourglass_empty,
          'Wait',
          _formatDate(task.wait!),
          colorScheme.primary,
        ),
      );
    }
    if (task.scheduled != null) {
      rows.add(
        _buildDetailRow(
          context,
          Icons.schedule,
          'Scheduled',
          _formatDate(task.scheduled!),
          colorScheme.secondary,
        ),
      );
    }
    if (task.until != null) {
      rows.add(
        _buildDetailRow(
          context,
          Icons.event_busy,
          'Until',
          _formatDate(task.until!),
          colorScheme.tertiary,
        ),
      );
    }
    if (task.start != null) {
      rows.add(
        _buildDetailRow(
          context,
          Icons.play_arrow,
          'Started',
          _formatDate(task.start!),
          Colors.amber.shade600,
        ),
      );
    }

    rows.add(
      _buildDetailRow(
        context,
        Icons.add_circle_outline,
        'Created',
        _formatDate(task.entry),
        colorScheme.onSurfaceVariant,
      ),
    );
    rows.add(
      _buildDetailRow(
        context,
        Icons.edit_note,
        'Modified',
        _formatDate(task.modified),
        colorScheme.onSurfaceVariant,
      ),
    );

    return Container(
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: colorScheme.outline.withValues(alpha: 0.1)),
      ),
      child: Column(
        children: rows.asMap().entries.map((entry) {
          final isLast = entry.key == rows.length - 1;
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                child: entry.value,
              ),
              if (!isLast)
                Divider(
                  height: 1,
                  indent: 48,
                  color: colorScheme.outline.withValues(alpha: 0.1),
                ),
            ],
          );
        }).toList(),
      ),
    );
  }

  Widget _buildRelationsCard(BuildContext context, ColorScheme colorScheme) {
    final rows = <Widget>[];

    if (task.tags.isNotEmpty) {
      rows.add(
        _buildDetailRow(
          context,
          Icons.label_outline,
          'Tags',
          null,
          colorScheme.onSurfaceVariant,
          customTrailing: Wrap(
            spacing: 6,
            runSpacing: 6,
            alignment: WrapAlignment.end,
            children: task.tags
                .map(
                  (t) => Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: colorScheme.secondaryContainer,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      t,
                      style: TextStyle(
                        fontSize: 12,
                        color: colorScheme.onSecondaryContainer,
                      ),
                    ),
                  ),
                )
                .toList(),
          ),
        ),
      );
    }

    if (task.priority != null) {
      Color pColor = colorScheme.onSurfaceVariant;
      if (task.priority == 'H') pColor = colorScheme.error;
      if (task.priority == 'M') pColor = colorScheme.tertiary;
      if (task.priority == 'L') pColor = colorScheme.primary;
      rows.add(
        _buildDetailRow(
          context,
          Icons.flag_outlined,
          'Priority',
          task.priority!,
          pColor,
        ),
      );
    }

    if (task.recurrence != null) {
      final instanceNumber = task.recurrenceIndex == null
          ? ''
          : '#${task.recurrenceIndex! + BigInt.one}';
      final recurrenceKind = task.isRecurringTemplate
          ? 'Series template'
          : task.isRecurringInstance
          ? 'Instance $instanceNumber'
          : 'Repeating task';
      rows.add(
        _buildDetailRow(
          context,
          Icons.loop,
          'Recurrence',
          '$recurrenceKind - ${task.recurrence!}',
          colorScheme.onSurfaceVariant,
        ),
      );
    }

    rows.add(
      _buildDetailRow(
        context,
        Icons.link,
        'Blocked By',
        null,
        colorScheme.onSurfaceVariant,
        customTrailing: task.depends.isEmpty
            ? Text(
                'None',
                style: TextStyle(
                  color: colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
                ),
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: task.depends
                    .map(
                      (uuid) =>
                          _buildDependencyLink(context, uuid, colorScheme),
                    )
                    .toList(),
              ),
      ),
    );

    return Container(
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: colorScheme.outline.withValues(alpha: 0.1)),
      ),
      child: Column(
        children: rows.asMap().entries.map((entry) {
          final isLast = entry.key == rows.length - 1;
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                child: entry.value,
              ),
              if (!isLast)
                Divider(
                  height: 1,
                  indent: 48,
                  color: colorScheme.outline.withValues(alpha: 0.1),
                ),
            ],
          );
        }).toList(),
      ),
    );
  }

  Widget _buildDetailRow(
    BuildContext context,
    IconData icon,
    String label,
    String? value,
    Color iconColor, {
    Widget? customTrailing,
  }) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 20, color: iconColor),
        const SizedBox(width: 16),
        Text(
          label,
          style: TextStyle(
            color: theme.colorScheme.onSurfaceVariant,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Align(
            alignment: Alignment.centerRight,
            child:
                customTrailing ??
                Text(
                  value ?? '',
                  style: TextStyle(
                    color: theme.colorScheme.onSurface,
                    fontWeight: FontWeight.w500,
                  ),
                  textAlign: TextAlign.right,
                ),
          ),
        ),
      ],
    );
  }

  Widget _buildDependencyLink(
    BuildContext context,
    String uuid,
    ColorScheme colorScheme,
  ) {
    final taskState = context.read<TaskState>();
    final name = taskState.getTaskDescription(uuid);

    return InkWell(
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => TaskDetailPage(taskUuid: uuid)),
        );
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.subdirectory_arrow_right,
              size: 14,
              color: Colors.grey,
            ),
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                name,
                style: TextStyle(
                  color: colorScheme.primary,
                  fontWeight: FontWeight.w500,
                  decoration: TextDecoration.underline,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildUdaTile(BuildContext context, ColorScheme colorScheme) {
    return Container(
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: colorScheme.outline.withValues(alpha: 0.1)),
      ),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          title: const Text(
            'Custom Attributes (UDAs)',
            style: TextStyle(fontWeight: FontWeight.w600),
          ),
          leading: Icon(
            Icons.extension_outlined,
            color: colorScheme.onSurfaceVariant,
          ),
          childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          children: [
            Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: colorScheme.outline.withValues(alpha: 0.1),
                ),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Table(
                  border: TableBorder(
                    horizontalInside: BorderSide(
                      color: colorScheme.outline.withValues(alpha: 0.1),
                    ),
                    verticalInside: BorderSide(
                      color: colorScheme.outline.withValues(alpha: 0.1),
                    ),
                  ),
                  children: task.udas.map((pair) {
                    return TableRow(
                      children: [
                        Padding(
                          padding: const EdgeInsets.all(12),
                          child: Text(
                            pair.key,
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              color: colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.all(12),
                          child: Text(pair.value),
                        ),
                      ],
                    );
                  }).toList(),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAnnotationsList(BuildContext context, ColorScheme colorScheme) {
    if (task.annotations.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Center(
          child: Text(
            'No notes added yet.',
            style: TextStyle(
              color: colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
            ),
          ),
        ),
      );
    }

    return Column(
      children: task.annotations.map((note) {
        return Container(
          margin: const EdgeInsets.only(bottom: 12),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: colorScheme.secondaryContainer.withValues(alpha: 0.4),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: colorScheme.secondaryContainer.withValues(alpha: 0.5),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text(
                      note.description,
                      style: const TextStyle(fontSize: 15, height: 1.4),
                    ),
                  ),
                  InkWell(
                    onTap: () {
                      HapticFeedback.mediumImpact();
                      _deleteAnnotation(context, note.entry);
                    },
                    borderRadius: BorderRadius.circular(20),
                    splashColor: colorScheme.error.withValues(alpha: 0.1),
                    child: Padding(
                      padding: const EdgeInsets.only(left: 12, bottom: 8),
                      child: Icon(
                        Icons.close,
                        size: 18,
                        color: colorScheme.onSurfaceVariant.withValues(
                          alpha: 0.5,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Icon(
                    Icons.access_time,
                    size: 12,
                    color: colorScheme.onSurfaceVariant.withValues(alpha: 0.8),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    _formatDate(note.entry),
                    style: TextStyle(
                      fontSize: 11,
                      color: colorScheme.onSurfaceVariant.withValues(
                        alpha: 0.8,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      }).toList(),
    );
  }

  Future<void> _deleteAnnotation(BuildContext context, String entryDate) async {
    final taskState = context.read<TaskState>();

    final error = await taskState.updateTask(
      task.uuid,
      UpdateTaskParams(
        removeAnnotations: [entryDate],
        addAnnotation: null,
        start: null,
        addTags: [],
        removeTags: [],
        addDepends: [],
        removeDepends: [],
        setUdas: [],
        description: null,
        status: null,
        project: null,
        priority: null,
        due: null,
        wait: null,
        scheduled: null,
        recurrence: null,
        until: null,
      ),
    );

    if (error != null && context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error)));
    }
  }

  Widget _buildSectionHeader(
    BuildContext context,
    String title, {
    double bottomPadding = 12,
  }) {
    return Padding(
      padding: EdgeInsets.only(bottom: bottomPadding, left: 4),
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

  String _formatDate(String dateStr) {
    try {
      final date = DateTime.parse(dateStr).toLocal();
      final monthNames = [
        'Jan',
        'Feb',
        'Mar',
        'Apr',
        'May',
        'Jun',
        'Jul',
        'Aug',
        'Sep',
        'Oct',
        'Nov',
        'Dec',
      ];
      final m = monthNames[date.month - 1];
      return "${date.day} $m ${date.year} ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}";
    } catch (_) {
      return dateStr;
    }
  }

  Future<void> _toggleStart(BuildContext context) async {
    final taskState = context.read<TaskState>();
    final isStarted = task.isActive;
    final targetState = !isStarted;

    final error = await taskState.updateTask(
      task.uuid,
      UpdateTaskParams(
        start: targetState,
        addTags: [],
        removeTags: [],
        addDepends: [],
        removeDepends: [],
        setUdas: [],
        description: null,
        status: null,
        project: null,
        priority: null,
        due: null,
        wait: null,
        scheduled: null,
        recurrence: null,
        until: null,
        addAnnotation: null,
        removeAnnotations: [],
      ),
    );

    if (error != null && context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error)));
    }
  }

  Future<void> _showAddNoteDialog(BuildContext context) async {
    final controller = TextEditingController();
    final result = await showDialog<String?>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Add Note'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(
            hintText: 'Enter your note...',
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
          ),
          maxLines: 3,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final text = controller.text.trim();
              Navigator.pop(ctx, text.isEmpty ? null : text);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );

    try {
      controller.dispose();
    } catch (_) {}

    if (result != null && result.isNotEmpty && context.mounted) {
      final taskState = context.read<TaskState>();
      final error = await Future.delayed(
        Duration.zero,
        () => taskState.updateTask(
          task.uuid,
          UpdateTaskParams(
            addAnnotation: result,
            removeAnnotations: [],
            start: null,
            addTags: [],
            removeTags: [],
            addDepends: [],
            removeDepends: [],
            setUdas: [],
            description: null,
            status: null,
            project: null,
            priority: null,
            due: null,
            wait: null,
            scheduled: null,
            recurrence: null,
            until: null,
          ),
        ),
      );
      if (error != null && context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error)));
      }
    }
  }

  Future<void> _markDone(BuildContext context) async {
    final taskState = context.read<TaskState>();
    if (task.isRecurringTemplate) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Recurring series templates cannot be completed. Delete the series or set Repeat Until instead.',
          ),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    final error = await taskState.markTaskDoneSingle(task.uuid);
    if (!context.mounted) return;

    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(error ?? 'Task completed'),
        behavior: SnackBarBehavior.floating,
        action: error == null
            ? SnackBarAction(label: 'Undo', onPressed: () => taskState.undo())
            : null,
      ),
    );

    if (error == null) Navigator.of(context).pop();
  }

  Future<void> _deleteTask(BuildContext context) async {
    final taskState = context.read<TaskState>();

    if (task.isRecurringTemplate || task.isRecurringInstance) {
      final scope = await showModalBottomSheet<SeriesScope>(
        context: context,
        builder: (ctx) => Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('This task only'),
              subtitle: const Text('Delete only this single task'),
              onTap: () => Navigator.pop(ctx, SeriesScope.single),
            ),
            ListTile(
              leading: const Icon(Icons.delete_sweep),
              title: const Text('Entire series'),
              subtitle: const Text('Delete this task and all its instances'),
              onTap: () => Navigator.pop(ctx, SeriesScope.entire),
            ),
          ],
        ),
      );

      if (scope == null) return;
      if (scope == SeriesScope.entire) {
        final error = await taskState.deleteTaskSeries(task.uuid);
        if (!context.mounted) return;
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(error ?? 'Series deleted'),
            behavior: SnackBarBehavior.floating,
            action: error == null
                ? SnackBarAction(
                    label: 'Undo',
                    onPressed: () => taskState.undo(),
                  )
                : null,
          ),
        );
        if (error == null && context.mounted) Navigator.of(context).pop();
        return;
      }
    }

    final error = await taskState.deleteTaskSingle(task.uuid);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(error ?? 'Task deleted'),
        behavior: SnackBarBehavior.floating,
        action: error == null
            ? SnackBarAction(label: 'Undo', onPressed: () => taskState.undo())
            : null,
      ),
    );
    if (error == null && context.mounted) Navigator.of(context).pop();
  }

  Future<void> _showEditDialog(BuildContext context) async {
    final taskState = Provider.of<TaskState>(context, listen: false);
    var editTarget = task;
    var mode = TaskEditorMode.normal;
    var updateSeries = false;

    if (task.isRecurringTemplate) {
      mode = TaskEditorMode.series;
      updateSeries = true;
    } else if (task.isRecurringInstance) {
      final scope = await _chooseRecurringEditScope(context);
      if (scope == null || !context.mounted) return;
      updateSeries = scope == SeriesScope.entire;
      mode = updateSeries ? TaskEditorMode.series : TaskEditorMode.instance;

      if (updateSeries) {
        final parentUuid = task.parentUuid;
        if (parentUuid == null) return;
        final parent = await taskState.getTaskByUuid(parentUuid);
        if (!context.mounted) return;
        if (parent == null) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Recurring series template not found'),
            ),
          );
          return;
        }
        editTarget = parent;
      }
    }

    final result = await showTaskEditorSheet(
      context,
      originalTask: editTarget,
      mode: mode,
    );

    if (result != null && context.mounted) {
      final updateParams = _createUpdateParams(editTarget, result);
      final error = updateSeries
          ? await taskState.updateTaskSeries(task.uuid, updateParams)
          : await taskState.updateTask(editTarget.uuid, updateParams);
      if (error != null && context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error)));
      }
    }
  }

  Future<SeriesScope?> _chooseRecurringEditScope(BuildContext context) {
    return showModalBottomSheet<SeriesScope>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.event_available_outlined),
              title: const Text('This instance only'),
              subtitle: const Text('Change just this occurrence'),
              onTap: () => Navigator.pop(ctx, SeriesScope.single),
            ),
            ListTile(
              leading: const Icon(Icons.all_inclusive),
              title: const Text('Entire series'),
              subtitle: const Text('Update the template and pending instances'),
              onTap: () => Navigator.pop(ctx, SeriesScope.entire),
            ),
          ],
        ),
      ),
    );
  }

  UpdateTaskParams _createUpdateParams(
    TaskView original,
    TaskEditorResult newResult,
  ) {
    final oldTags = Set<String>.from(original.tags);
    final newTags = Set<String>.from(newResult.tags);
    final addTags = newTags.difference(oldTags).toList();
    final removeTags = oldTags.difference(newTags).toList();

    String? resolveDate(String? oldIso, DateTime? newDate) {
      final newIso = newDate?.toUtc().toIso8601String();
      if (oldIso == newIso) return null;
      if (newDate == null) return "";
      return newIso;
    }

    final oldDeps = Set<String>.from(original.depends);
    final newDeps = Set<String>.from(newResult.dependencies);
    final addDeps = newDeps.difference(oldDeps).toList();
    final removeDeps = oldDeps.difference(newDeps).toList();

    final oldUdaMap = {
      for (var u in original.udas)
        if (u.key != 'recur' && u.key != 'until') u.key: u.value,
    };
    final newUdaMap = {for (var u in newResult.udas) u.key: u.value};

    final udasToSend = <UdaPair>[];

    newUdaMap.forEach((key, val) {
      if (!oldUdaMap.containsKey(key) || oldUdaMap[key] != val) {
        udasToSend.add(UdaPair(key: key, value: val));
      }
    });

    oldUdaMap.forEach((key, val) {
      if (!newUdaMap.containsKey(key)) {
        udasToSend.add(UdaPair(key: key, value: ""));
      }
    });

    final newDesc = newResult.description;
    final newProj = newResult.project ?? '';
    final newPrio = newResult.priority ?? 'X';
    final newRecurrence = (newResult.recurrence ?? '').trim();

    return UpdateTaskParams(
      description: newDesc != original.description ? newDesc : null,
      status: null,
      project: newProj != (original.project ?? '') ? newProj : null,
      priority: newPrio != (original.priority ?? '')
          ? (newPrio == 'X' ? '' : newPrio)
          : null,
      due: resolveDate(original.due, newResult.due),
      wait: resolveDate(original.wait, newResult.wait),
      scheduled: resolveDate(original.scheduled, newResult.scheduled),
      until: resolveDate(original.until, newResult.until),
      recurrence: newRecurrence != (original.recurrence ?? '')
          ? newRecurrence
          : null,
      addTags: addTags,
      removeTags: removeTags,
      addDepends: addDeps,
      removeDepends: removeDeps,
      setUdas: udasToSend,
      addAnnotation: null,
      removeAnnotations: [],
      start: null,
    );
  }
}
