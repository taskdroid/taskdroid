import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:taskdroid/providers/task_state.dart';

class FilterSideSheet extends StatelessWidget {
  const FilterSideSheet({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Drawer(
      width: MediaQuery.of(context).size.width * 0.85,
      child: Consumer<TaskState>(
        builder: (context, taskState, _) {
          return Column(
            children: [
              DrawerHeader(
                decoration: BoxDecoration(color: theme.colorScheme.surface),
                child: Row(
                  children: [
                    Text('Filters', style: theme.textTheme.headlineMedium),
                    const Spacer(),
                    IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () => Navigator.pop(context),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  children: [
                    if (taskState.allTags.isNotEmpty) ...[
                      _buildSectionTitle(context, 'Tags'),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: taskState.allTags.map((tag) {
                          final isSelected = taskState.selectedTags.contains(
                            tag,
                          );
                          return FilterChip(
                            label: Text(tag),
                            selected: isSelected,
                            onSelected: (_) => taskState.toggleTag(tag),
                          );
                        }).toList(),
                      ),
                      const Divider(height: 32),
                    ],

                    if (taskState.allProjects.isNotEmpty) ...[
                      _buildSectionTitle(context, 'Projects'),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: taskState.allProjects.map((project) {
                          final isSelected = taskState.selectedProjects
                              .contains(project);
                          return FilterChip(
                            label: Text(project),
                            selected: isSelected,
                            onSelected: (_) => taskState.toggleProject(project),
                          );
                        }).toList(),
                      ),
                      const Divider(height: 32),
                    ],
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(16.0),
                child: SizedBox(
                  width: double.infinity,
                  child: OutlinedButton(
                    onPressed: () {
                      taskState.clearFilters();
                    },
                    child: const Text('Clear All Filters'),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildSectionTitle(BuildContext context, String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12.0),
      child: Text(
        title,
        style: Theme.of(context).textTheme.titleMedium?.copyWith(
          fontWeight: FontWeight.bold,
          color: Theme.of(context).colorScheme.primary,
        ),
      ),
    );
  }
}
