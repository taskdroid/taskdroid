import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:taskdroid/providers/app_state.dart';
import 'package:taskdroid/providers/profile_state.dart';
import 'package:taskdroid/providers/task_state.dart';
import 'package:taskdroid/services/calendar_service.dart';
import 'package:taskdroid/widgets/app_drawer.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  String _getActionName(SwipeAction action) {
    switch (action) {
      case SwipeAction.none:
        return 'None';
      case SwipeAction.markDone:
        return 'Mark Done';
      case SwipeAction.delete:
        return 'Delete';
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final appState = context.watch<AppState>();
    final profileState = context.watch<ProfileState>();
    final currentProfile = profileState.currentProfile;

    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Settings',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
      ),
      drawer: const AppDrawer(currentRoute: '/settings'),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
        children: [
          _buildSectionHeader(context, 'Appearance'),
          _buildSettingGroup(
            context,
            children: [
              SwitchListTile(
                title: const Text(
                  'Dark theme',
                  style: TextStyle(fontWeight: FontWeight.w500),
                ),
                subtitle: const Text('Reduces eye strain in low light'),
                value: appState.isDarkTheme,
                onChanged: (value) =>
                    context.read<AppState>().setDarkTheme(value),
              ),
            ],
          ),

          const SizedBox(height: 24),

          _buildSectionHeader(context, 'Sync & Integration'),
          _buildSettingGroup(
            context,
            children: [
              SwitchListTile(
                title: const Text(
                  'Sync on start',
                  style: TextStyle(fontWeight: FontWeight.w500),
                ),
                subtitle: const Text('Automatically sync when the app opens'),
                value: appState.syncOnStart,
                onChanged: (value) =>
                    context.read<AppState>().setSyncOnStart(value),
              ),
              const Divider(indent: 16, endIndent: 16, height: 1),
              SwitchListTile(
                title: const Text(
                  'System Calendar Sync',
                  style: TextStyle(fontWeight: FontWeight.w500),
                ),
                subtitle: Text(
                  currentProfile == null
                      ? 'Select a profile to enable'
                      : 'Mirror tasks to ${currentProfile.name}\'s calendar',
                  style: TextStyle(
                    color: currentProfile == null ? colorScheme.error : null,
                  ),
                ),
                value: currentProfile?.calendarSync ?? false,
                onChanged: currentProfile == null
                    ? null
                    : (value) => _handleCalendarToggle(context, value),
              ),
              const Divider(indent: 16, endIndent: 16, height: 1),
              ListTile(
                title: const Text(
                  'Recurring instances ahead',
                  style: TextStyle(fontWeight: FontWeight.w500),
                ),
                subtitle: Text(
                  currentProfile == null
                      ? 'Select a profile to configure'
                      : 'Number of pending recurring instances to generate (Off stops generation).',
                  style: TextStyle(
                    color: currentProfile == null ? colorScheme.error : null,
                  ),
                ),
                trailing: SizedBox(
                  width: 120,
                  child: DropdownButtonFormField<int>(
                    initialValue: (currentProfile?.recurrenceLimit ?? 1).clamp(
                      0,
                      5,
                    ),
                    isExpanded: true,
                    decoration: const InputDecoration(isDense: true),
                    items: const [0, 1, 2, 3, 4, 5]
                        .map(
                          (value) => DropdownMenuItem<int>(
                            value: value,
                            child: Text(value == 0 ? 'Off' : '$value'),
                          ),
                        )
                        .toList(),
                    onChanged: currentProfile == null
                        ? null
                        : (value) async {
                            if (value == null) return;
                            await context
                                .read<ProfileState>()
                                .setRecurrenceLimitForCurrentProfile(value);
                            if (!context.mounted) return;
                            final error = await context
                                .read<TaskState>()
                                .setRecurrenceLimit(value);
                            if (!context.mounted) return;
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(
                                  error ??
                                      (value == 0
                                          ? 'Recurring instance generation disabled'
                                          : 'Recurring instance limit set to $value'),
                                ),
                              ),
                            );
                          },
                  ),
                ),
              ),
            ],
          ),

          const SizedBox(height: 24),

          _buildSectionHeader(context, 'Gestures'),
          _buildSettingGroup(
            context,
            padding: const EdgeInsets.all(20),
            children: [
              _buildSwipeDropdown(
                context,
                'Swipe Right',
                'Action when swiping from left to right',
                appState.rightSwipeAction,
                (val) => appState.setRightSwipeAction(val),
              ),
              const SizedBox(height: 20),
              _buildSwipeDropdown(
                context,
                'Swipe Left',
                'Action when swiping from right to left',
                appState.leftSwipeAction,
                (val) => appState.setLeftSwipeAction(val),
              ),
            ],
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

  Widget _buildSettingGroup(
    BuildContext context, {
    required List<Widget> children,
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
      child: Padding(
        padding: padding ?? EdgeInsets.zero,
        child: Column(children: children),
      ),
    );
  }

  Widget _buildSwipeDropdown(
    BuildContext context,
    String label,
    String subtitle,
    SwipeAction current,
    Function(SwipeAction) onChanged,
  ) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
        ),
        Text(
          subtitle,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 12),
        DropdownButtonFormField<SwipeAction>(
          initialValue: current,
          isExpanded: true,
          decoration: const InputDecoration(
            contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          ),
          items: SwipeAction.values.map((action) {
            return DropdownMenuItem(
              value: action,
              child: Text(_getActionName(action)),
            );
          }).toList(),
          onChanged: (val) {
            if (val != null) onChanged(val);
          },
        ),
      ],
    );
  }

  Future<void> _handleCalendarToggle(BuildContext context, bool enabled) async {
    final profileState = context.read<ProfileState>();
    final taskState = context.read<TaskState>();
    final calendarService = CalendarService();

    if (enabled) {
      final hasPermission = await calendarService.requestPermissions();
      if (!context.mounted) return;

      if (!hasPermission) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Calendar permission is required to enable sync'),
          ),
        );
        return;
      }

      await profileState.setCalendarSyncForCurrentProfile(true);
      if (!context.mounted) return;

      // reload tasks and perform batch sync
      final currentP = profileState.currentProfile;
      if (currentP != null) {
        await taskState.loadProfile(currentP);
        await taskState.refreshPendingTasks();

        final allTasksToSync = [
          ...taskState.pendingTasks,
          ...taskState.waitingTasks,
          ...taskState.scheduledTasks,
        ];
        await calendarService.batchSync(allTasksToSync);
      }

      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Calendar sync enabled. Tasks are mirroring now.'),
        ),
      );
    } else {
      final shouldDelete = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Remove Calendar Events?'),
          content: const Text(
            'Do you want to clear all Taskdroid events from your system calendar?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Keep Events'),
            ),
            FilledButton.tonal(
              onPressed: () => Navigator.pop(ctx, true),
              style: FilledButton.styleFrom(
                foregroundColor: Theme.of(context).colorScheme.error,
                backgroundColor: Theme.of(context).colorScheme.errorContainer,
              ),
              child: const Text('Remove All'),
            ),
          ],
        ),
      );

      if (!context.mounted) return;

      if (shouldDelete == true) {
        final count = await calendarService.deleteAllEvents();
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Removed $count events from calendar')),
          );
        }
      }

      await profileState.setCalendarSyncForCurrentProfile(false);
    }
  }
}
