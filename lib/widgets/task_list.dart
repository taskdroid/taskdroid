import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:taskdroid/providers/app_state.dart';
import 'package:taskdroid/providers/task_state.dart';
import 'package:taskdroid/src/rust/api.dart';
import 'package:taskdroid/views/task_detail.dart';

class TaskList extends StatelessWidget {
  const TaskList({super.key, required this.tasks});

  final List<TaskView> tasks;

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 120),
      itemCount: tasks.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, index) => TaskListItem(task: tasks[index]),
    );
  }
}

class TaskListItem extends StatelessWidget {
  const TaskListItem({super.key, required this.task});

  final TaskView task;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final appState = context.watch<AppState>();
    final taskState = context.watch<TaskState>();

    final isSelected = taskState.selectedTaskUuids.contains(task.uuid);
    final isSelectionMode = taskState.isSelectionMode;

    final borderRadius = BorderRadius.circular(16);

    final tile = Card(
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: borderRadius,
        side: BorderSide(
          color: isSelected
              ? colorScheme.primary
              : colorScheme.outlineVariant.withValues(alpha: 0.5),
          width: isSelected ? 2 : 1,
        ),
      ),
      color: isSelected ? colorScheme.primaryContainer : colorScheme.surface,
      clipBehavior: Clip.antiAlias, // Ensures InkWell respects border radius
      child: InkWell(
        onTap: () {
          if (isSelectionMode) {
            taskState.toggleTaskSelection(task.uuid);
            return;
          }
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => TaskDetailPage(taskUuid: task.uuid),
            ),
          );
        },
        onLongPress: () => taskState.toggleTaskSelection(task.uuid),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 2, right: 12),
                child: Icon(
                  isSelected ? Icons.check_circle : Icons.circle_outlined,
                  size: 22,
                  color: isSelected ? colorScheme.primary : colorScheme.outline,
                ),
              ),

              // Text Content
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            task.description,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                              height: 1.2,
                            ),
                          ),
                        ),
                        if (task.isActive) ...[
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.amber.shade600,
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: const Icon(
                              Icons.play_arrow_rounded,
                              size: 16,
                              color: Colors.black,
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      _buildMetadata(task),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),

              // Urgency Pill
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: _urgencyColor(
                    task.urgency,
                    colorScheme,
                  ).withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  task.urgency.toStringAsFixed(1),
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: _urgencyColor(task.urgency, colorScheme),
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    if (isSelectionMode) {
      return tile;
    }

    return Dismissible(
      key: Key(task.uuid),
      background: _buildSwipeBackground(
        context,
        appState.leftSwipeAction,
        Alignment.centerLeft,
      ),
      secondaryBackground: _buildSwipeBackground(
        context,
        appState.rightSwipeAction,
        Alignment.centerRight,
      ),
      confirmDismiss: (direction) async {
        final action = direction == DismissDirection.startToEnd
            ? appState.leftSwipeAction
            : appState.rightSwipeAction;

        if (action == SwipeAction.none) return false;

        if (action == SwipeAction.delete) {
          final error = await taskState.deleteTask(task.uuid);
          if (!context.mounted) return false;
          _showSnack(
            context,
            error ?? 'Task deleted',
            taskState,
            canUndo: error == null,
          );
          return error == null;
        }

        if (task.isRecurringTemplate) {
          _showSnack(
            context,
            'Recurring series templates cannot be completed. Delete the series or set Repeat Until instead.',
            taskState,
            canUndo: false,
          );
          return false;
        }

        final error = await taskState.markTaskDone(task.uuid);
        if (!context.mounted) return false;
        _showSnack(
          context,
          error ?? 'Task done',
          taskState,
          canUndo: error == null,
        );
        return error == null;
      },
      child: tile,
    );
  }

  String _buildMetadata(TaskView task) {
    final parts = <String>[];

    if (task.project != null && task.project!.isNotEmpty) {
      parts.add(task.project!);
    }

    if (task.tags.isNotEmpty) {
      parts.add(task.tags.join(', '));
    }

    if (task.due != null) {
      parts.add(_formatDate(task.due!));
    }

    if (task.recurrence != null && task.recurrence!.isNotEmpty) {
      if (task.isRecurringInstance) {
        parts.add('Instance - ${task.recurrence!}');
      } else if (task.isRecurringTemplate) {
        parts.add('Series - ${task.recurrence!}');
      } else {
        parts.add('Repeats ${task.recurrence!}');
      }
    }

    if (parts.isEmpty) {
      return 'No metadata';
    }

    return parts.join(' • ');
  }

  void _showSnack(
    BuildContext context,
    String message,
    TaskState taskState, {
    required bool canUndo,
  }) {
    final theme = Theme.of(context);
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        backgroundColor: theme.colorScheme.inverseSurface,
        action: canUndo
            ? SnackBarAction(
                label: 'Undo',
                textColor: theme.colorScheme.onInverseSurface,
                onPressed: () => taskState.undo(),
              )
            : null,
      ),
    );
  }

  Widget _buildSwipeBackground(
    BuildContext context,
    SwipeAction action,
    Alignment alignment,
  ) {
    if (action == SwipeAction.none) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isDelete = action == SwipeAction.delete;

    final color = isDelete
        ? colorScheme.errorContainer
        : colorScheme.secondaryContainer;
    final iconColor = isDelete
        ? colorScheme.onErrorContainer
        : colorScheme.onSecondaryContainer;
    final icon = isDelete ? Icons.delete_outline : Icons.check;
    final text = isDelete ? 'Delete' : 'Done';

    return Container(
      alignment: alignment,
      padding: const EdgeInsets.symmetric(horizontal: 24),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (alignment == Alignment.centerRight)
            Text(
              text,
              style: TextStyle(color: iconColor, fontWeight: FontWeight.bold),
            ),
          if (alignment == Alignment.centerRight) const SizedBox(width: 8),
          Icon(icon, color: iconColor),
          if (alignment == Alignment.centerLeft) const SizedBox(width: 8),
          if (alignment == Alignment.centerLeft)
            Text(
              text,
              style: TextStyle(color: iconColor, fontWeight: FontWeight.bold),
            ),
        ],
      ),
    );
  }

  static String _formatDate(String dateStr) {
    try {
      final date = DateTime.parse(dateStr).toLocal();
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      final target = DateTime(date.year, date.month, date.day);

      final hasTime = date.hour != 0 || date.minute != 0;
      final timeSuffix = hasTime
          ? ' ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}'
          : '';

      if (target == today) return 'Today$timeSuffix';
      if (target == today.add(const Duration(days: 1))) {
        return 'Tomorrow$timeSuffix';
      }

      const monthNames = [
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
      final month = monthNames[date.month - 1];

      if (date.year == now.year) {
        return '${date.day} $month$timeSuffix';
      }

      return '${date.day} $month ${date.year}$timeSuffix';
    } catch (_) {
      return dateStr;
    }
  }

  Color _urgencyColor(double urgency, ColorScheme colorScheme) {
    if (urgency >= 20) return colorScheme.error;
    if (urgency >= 10) return colorScheme.tertiary;
    if (urgency >= 5) return Colors.amber.shade600;
    return colorScheme.onSurfaceVariant;
  }
}
