import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:taskdroid/providers/task_state.dart';
import 'package:taskdroid/src/rust/api.dart';
import 'package:taskdroid/theme/tokens.dart';
import 'package:taskdroid/widgets/common/app_sheet.dart';

class TaskSelector extends StatefulWidget {
  final List<String> excludedUuids;

  const TaskSelector({super.key, required this.excludedUuids});

  @override
  State<TaskSelector> createState() => _TaskSelectorState();
}

class _TaskSelectorState extends State<TaskSelector> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Header (the drag handle comes from the theme)
        const AppSheetHeader(title: 'Select Dependency'),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpace.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  autofocus: true,
                  onChanged: (val) =>
                      setState(() => _query = val.toLowerCase()),
                  decoration: InputDecoration(
                    hintText: 'Search by description or project...',
                    prefixIcon: const Icon(Icons.search_rounded),
                    filled: true,
                    fillColor: colorScheme.surfaceContainerHighest.withValues(
                      alpha: 0.5,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(AppRadius.input),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
                const SizedBox(height: AppSpace.xl),
                Expanded(
                  child: Consumer<TaskState>(
                    builder: (context, state, _) {
                      final tasks = state.dependencyCandidates.where((t) {
                        // filter out already selected or self-referencing tasks
                        if (widget.excludedUuids.contains(t.uuid)) return false;

                        // filter by query
                        if (_query.isEmpty) return true;
                        final matchDesc = t.description.toLowerCase().contains(
                          _query,
                        );
                        final matchProj =
                            t.project?.toLowerCase().contains(_query) ?? false;
                        return matchDesc || matchProj;
                      }).toList();

                      if (tasks.isEmpty) {
                        return Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                Icons.search_off_rounded,
                                size: 48,
                                color: colorScheme.outline,
                              ),
                              const SizedBox(height: AppSpace.md),
                              Text(
                                'No matching tasks found',
                                style: TextStyle(
                                  color: colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        );
                      }

                      return ListView.separated(
                        keyboardDismissBehavior:
                            ScrollViewKeyboardDismissBehavior.onDrag,
                        physics: const BouncingScrollPhysics(),
                        itemCount: tasks.length,
                        separatorBuilder: (_, _) =>
                            const SizedBox(height: AppSpace.sm),
                        itemBuilder: (context, index) {
                          final task = tasks[index];
                          return _buildTaskItem(
                            context,
                            theme,
                            colorScheme,
                            task,
                          );
                        },
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildTaskItem(
    BuildContext context,
    ThemeData theme,
    ColorScheme colorScheme,
    TaskView task,
  ) {
    return InkWell(
      onTap: () => Navigator.pop(context, task.uuid),
      borderRadius: BorderRadius.circular(AppRadius.control),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(AppRadius.control),
          border: Border.all(color: colorScheme.outline.withValues(alpha: 0.1)),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: colorScheme.primary.withValues(alpha: 0.1),
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.link_rounded,
                size: 18,
                color: colorScheme.primary,
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    task.description,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (task.project != null && task.project!.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        task.project!,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colorScheme.primary,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Icon(Icons.chevron_right_rounded, color: colorScheme.outline),
          ],
        ),
      ),
    );
  }
}
