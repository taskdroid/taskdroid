import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:taskdroid/models/profile.dart';
import 'package:taskdroid/providers/app_state.dart';
import 'package:taskdroid/providers/profile_state.dart';
import 'package:taskdroid/providers/task_state.dart';
import 'package:taskdroid/services/calendar_service.dart';
import 'package:taskdroid/services/profile_storage.dart';
import 'package:taskdroid/services/storage_locations.dart';
import 'package:taskdroid/services/storage_permissions.dart';
import 'package:taskdroid/widgets/app_drawer.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
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

          _buildSectionHeader(context, 'Storage'),
          _buildStorageSection(context),

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

  Widget _buildStorageSection(BuildContext context) {
    return FutureBuilder<String>(
      future: getGlobalStoragePath(),
      builder: (context, snapshot) {
        final basePath = snapshot.data ?? 'Loading...';
        return _buildSettingGroup(
          context,
          children: [
            ListTile(
              title: const Text(
                'Storage location',
                style: TextStyle(fontWeight: FontWeight.w500),
              ),
              subtitle: Text(
                basePath,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: IconButton(
                onPressed: () => _copyStoragePath(context, basePath),
                icon: const Icon(Icons.copy_rounded, size: 18),
                tooltip: 'Copy path',
              ),
            ),
            const Divider(indent: 16, endIndent: 16, height: 1),
            ListTile(
              title: const Text(
                'Change storage location',
                style: TextStyle(fontWeight: FontWeight.w500),
              ),
              subtitle: const Text('Choose from app-accessible folders only'),
              trailing: const Icon(Icons.folder_rounded),
              onTap: () => _selectStorageLocation(context),
            ),
            const Divider(indent: 16, endIndent: 16, height: 1),
            ListTile(
              title: const Text(
                'Reset to default',
                style: TextStyle(fontWeight: FontWeight.w500),
              ),
              subtitle: const Text('Use the app data directory again'),
              trailing: Icon(Icons.restore_rounded),
              onTap: () => _resetStorageLocation(context),
            ),
          ],
        );
      },
    );
  }

  Future<void> _copyStoragePath(BuildContext context, String path) async {
    try {
      await Clipboard.setData(ClipboardData(text: path));
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Storage path copied')),
      );
    } catch (_) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Unable to access storage path')),
      );
    }
  }

  Future<void> _selectStorageLocation(BuildContext context) async {
    final profileState = context.read<ProfileState>();

    final locations = await getAvailableStorageLocations();
    if (!context.mounted) return;

    final currentPath = await getGlobalStoragePath();

    final result = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        return SafeArea(
          child: ListView.separated(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
            itemBuilder: (context, index) {
              if (index == locations.length) {
                return ListTile(
                  leading: const Icon(Icons.folder_open_rounded),
                  title: const Text(
                    'Pick a folder from device…',
                    style: TextStyle(fontWeight: FontWeight.w500),
                  ),
                  subtitle: const Text('Browse internal storage'),
                  onTap: () => Navigator.pop(ctx, '__picker__'),
                );
              }
              final location = locations[index];
              final isSelected = currentPath == location.path;
              return ListTile(
                title: Text(location.label),
                subtitle: Text(
                  location.path,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing:
                    isSelected ? const Icon(Icons.check_rounded) : null,
                onTap: () => Navigator.pop(ctx, location.path),
              );
            },
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemCount: locations.length + 1,
          ),
        );
      },
    );

    if (!context.mounted || result == null) return;

    if (result == '__picker__') {
      await _pickCustomFolder(context);
      return;
    }

    final defaultPath = await getDefaultStoragePath();
    final normalizedPath = result == defaultPath ? null : result;

    if ((normalizedPath ?? defaultPath) == currentPath) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Storage location unchanged')),
      );
      return;
    }

    await _applyStoragePath(context, normalizedPath, profileState);
  }

  Future<bool> _ensureWritable(Directory dir) async {
    try {
      if (!await dir.exists()) await dir.create(recursive: true);
      final probeFile = File('${dir.path}/.taskdroid_wtest');
      await probeFile.writeAsString('ok');
      await probeFile.delete();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _pickCustomFolder(BuildContext context) async {
    final profileState = context.read<ProfileState>();

    final realPath = await pickStorageDirectory();
    if (!context.mounted || realPath == null) return;

    final dir = Directory(realPath);
    if (!await _ensureWritable(dir)) {
      if (!context.mounted) return;

      final granted = await StoragePermissions.requestPermission();
      if (!granted || !context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Cannot write to that folder without "All files access" permission',
            ),
          ),
        );
        return;
      }

      if (!await _ensureWritable(dir)) {
        if (!context.mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Still unable to write to that folder')),
        );
        return;
      }
    }

    await _applyStoragePath(context, realPath, profileState);
  }

  Future<void> _deleteOldProfileDirs(String oldPath, List<Profile> profiles) async {
    for (final profile in profiles) {
      final dirName = sanitizeProfileName(profile.name);
      final dir = Directory('$oldPath/$dirName/');
      if (await dir.exists()) {
        try { await dir.delete(recursive: true); } catch (e) {
          debugPrint('Failed to delete old dir for ${profile.id}: $e');
        }
      }
      final legacyDir = Directory('$oldPath/${profile.id}/');
      if (await legacyDir.exists()) {
        try { await legacyDir.delete(recursive: true); } catch (e) {
          debugPrint('Failed to delete legacy dir for ${profile.id}: $e');
        }
      }
    }
  }

  Future<void> _applyStoragePath(
    BuildContext context,
    String? path,
    ProfileState profileState,
  ) async {
    final oldPath = await getGlobalStoragePath();
    final newPath = path ?? await getDefaultStoragePath();
    if (oldPath == newPath) return;

    bool copyData = true;
    bool deleteOld = false;

    final action = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            return AlertDialog(
              title: const Text('Change storage location'),
              content: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('Current: $oldPath'),
                    const SizedBox(height: 4),
                    Text('New:    $newPath'),
                    const SizedBox(height: 20),
                    CheckboxListTile(
                      title: const Text('Copy profile data to new location'),
                      subtitle: const Text(
                        'Migrate TaskChampion databases to the new path',
                      ),
                      value: copyData,
                      contentPadding: EdgeInsets.zero,
                      onChanged: (v) =>
                          setDialogState(() => copyData = v ?? true),
                    ),
                    CheckboxListTile(
                      title: const Text(
                        'Delete profile folders from old location',
                      ),
                      subtitle: const Text(
                        'Only available when copying data',
                      ),
                      value: deleteOld,
                      contentPadding: EdgeInsets.zero,
                      onChanged: copyData
                          ? (v) => setDialogState(() => deleteOld = v ?? false)
                          : null,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'The app will restart for changes to take effect.',
                      style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                            color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                          ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, null),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(ctx, 'apply'),
                  child: const Text('Apply & Restart'),
                ),
              ],
            );
          },
        );
      },
    );

    if (!context.mounted || action != 'apply') return;

    if (copyData) {
      final failures = await migrateProfilesToNewPath(
        oldPath: oldPath,
        newPath: newPath,
        profiles: profileState.profiles,
        deleteSource: deleteOld,
      );

      if (failures.isNotEmpty) {
        if (!context.mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Migration failed for one or more profiles'),
          ),
        );
        return;
      }

      if (deleteOld) {
        final migratedProfiles = profileState.profiles
            .where((profile) => !failures.contains(profile))
            .toList();
        await _deleteOldProfileDirs(oldPath, migratedProfiles);
      }
    }

    await setGlobalStoragePath(path);
    if (!context.mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Restarting…')),
    );
    await Future.delayed(const Duration(milliseconds: 800));
    await SystemNavigator.pop();
  }

  Future<void> _resetStorageLocation(BuildContext context) async {
    final profileState = context.read<ProfileState>();

    await _applyStoragePath(context, null, profileState);
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
