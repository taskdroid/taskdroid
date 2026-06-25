import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:taskdroid/models/filter_tab.dart';
import 'package:taskdroid/models/task_context.dart';
import 'package:taskdroid/providers/app_state.dart';
import 'package:taskdroid/providers/profile_state.dart';
import 'package:taskdroid/providers/task_state.dart';
import 'package:taskdroid/services/task_queue_service.dart' show TaskQueueView;
import 'package:taskdroid/services/task_query_autocomplete.dart';
import 'package:taskdroid/services/task_query_language.dart';
import 'package:taskdroid/services/write_query_parser.dart';
import 'package:taskdroid/src/rust/api.dart';
import 'package:taskdroid/views/onboarding.dart';
import 'package:taskdroid/widgets/app_drawer.dart';
import 'package:taskdroid/widgets/filter_tabs.dart';
import 'package:taskdroid/widgets/task_list.dart';
import 'package:taskdroid/widgets/task_editor.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage>
    with SingleTickerProviderStateMixin {
  String? _lastProfileId;
  bool _hasAttemptedSyncOnStart = false;
  bool _hasInitializedProfile = false;
  bool _isSearchVisible = false;

  late final AnimationController _syncAnimController;

  @override
  void initState() {
    super.initState();
    _syncAnimController = AnimationController(
      duration: const Duration(seconds: 1),
      vsync: this,
    );
  }

  String _emptyStateSubtitle(TaskQueueView queueView) {
    switch (queueView) {
      case TaskQueueView.ready:
        return 'Add your next task to get started.';
      case TaskQueueView.waiting:
        return 'Tasks with future wait dates will appear here.';
      case TaskQueueView.scheduled:
        return 'Tasks scheduled for the future will appear here.';
    }
  }

  String _emptyStateButtonText(TaskQueueView queueView) {
    switch (queueView) {
      case TaskQueueView.ready:
        return 'Add task';
      case TaskQueueView.waiting:
        return 'Switch to Ready';
      case TaskQueueView.scheduled:
        return 'Switch to Ready';
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_hasInitializedProfile) {
      _hasInitializedProfile = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _doInitialProfileLoad();
      });
    }
  }

  void _doInitialProfileLoad() {
    final profileState = context.read<ProfileState>();
    final taskState = context.read<TaskState>();
    final appState = context.read<AppState>();

    if (profileState.currentProfile != null) {
      taskState.loadProfile(profileState.currentProfile!);
      _lastProfileId = profileState.currentProfileId;
      _hasAttemptedSyncOnStart = false;
      _handleSyncOnStart(context, appState, profileState, taskState);
    }
  }

  @override
  void dispose() {
    _syncAnimController.dispose();
    super.dispose();
  }

  void _handleSyncOnStart(
    BuildContext context,
    AppState appState,
    ProfileState profileState,
    TaskState taskState,
  ) {
    if (_hasAttemptedSyncOnStart) return;
    if (!appState.syncOnStart) return;

    final profile = profileState.currentProfile;
    if (profile == null || profile.serverUrl.isEmpty) return;
    if (taskState.currentProfileId != profile.id) return;

    _hasAttemptedSyncOnStart = true;

    taskState.sync(profile).then((error) {
      if (!context.mounted) return;
      final theme = Theme.of(context);
      if (error != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Auto-sync failed: $error',
              style: TextStyle(color: theme.colorScheme.onError),
            ),
            backgroundColor: theme.colorScheme.error,
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Auto-synced successfully',
              style: TextStyle(color: theme.colorScheme.onPrimaryContainer),
            ),
            backgroundColor: theme.colorScheme.primaryContainer,
            duration: const Duration(seconds: 2),
          ),
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final taskState = context.watch<TaskState>();
    final profileState = context.watch<ProfileState>();
    final appState = context.watch<AppState>();

    if (profileState.currentProfileId != _lastProfileId) {
      _lastProfileId = profileState.currentProfileId;
      _hasAttemptedSyncOnStart = false;
      if (profileState.currentProfile != null) {
        final profile = profileState.currentProfile!;

        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            taskState.loadProfile(profile);
            _handleSyncOnStart(context, appState, profileState, taskState);
          }
        });
      }
    }

    // anim control for sync icon
    if (taskState.isSyncing) {
      if (!_syncAnimController.isAnimating) _syncAnimController.repeat();
    } else {
      if (_syncAnimController.isAnimating) _syncAnimController.reset();
    }

    // check for onboarding
    if (profileState.isLoaded && profileState.profiles.isEmpty) {
      return Scaffold(
        backgroundColor: Theme.of(context).colorScheme.surface,
        body: SafeArea(child: OnboardingPage(onComplete: () {})),
      );
    }

    // standard app layout
    return Scaffold(
      drawer: const AppDrawer(currentRoute: '/'),
      appBar: taskState.isSelectionMode
          ? _buildSelectionBar(context, taskState)
          : _buildTopBar(context, taskState),
      floatingActionButton: taskState.isSelectionMode
          ? null
          : FloatingActionButton.extended(
              elevation: 2,
              onPressed: () => _showCreateSheet(context),
              icon: const Icon(Icons.add),
              label: const Text('New Task'),
            ),
      body: _buildMainBody(context, profileState, taskState),
    );
  }

  Widget _buildMainBody(
    BuildContext context,
    ProfileState profileState,
    TaskState taskState,
  ) {
    if (profileState.currentProfile == null) {
      return const _NoProfileState();
    }

    final usesExplicitStatusScope = taskState.usesExplicitStatusScope;

    return Column(
      children: [
        if (taskState.isSyncing) const LinearProgressIndicator(minHeight: 2),
        const FilterTabsRow(),
        if (usesExplicitStatusScope)
          _BroadResultsBar(
            resultCount: taskState.filteredTasks.length,
            isSearchVisible: _isSearchVisible,
            hasActiveFilters:
                taskState.searchQuery.trim().isNotEmpty ||
                taskState.includeTags.isNotEmpty ||
                taskState.excludeTags.isNotEmpty ||
                taskState.includeProjects.isNotEmpty ||
                taskState.excludeProjects.isNotEmpty,
            onToggleSearch: () {
              setState(() {
                _isSearchVisible = !_isSearchVisible;
              });
            },
          )
        else
          _QueueViewAndSearchToggleRow(
            selected: taskState.queueView,
            readyCount: taskState.pendingTasks.length,
            waitingCount: taskState.waitingTasks.length,
            scheduledCount: taskState.scheduledTasks.length,
            onSelected: taskState.setQueueView,
            isSearchVisible: _isSearchVisible,
            onToggleSearch: () {
              setState(() {
                _isSearchVisible = !_isSearchVisible;
              });
            },
            hasActiveFilters:
                taskState.searchQuery.trim().isNotEmpty ||
                taskState.includeTags.isNotEmpty ||
                taskState.excludeTags.isNotEmpty ||
                taskState.includeProjects.isNotEmpty ||
                taskState.excludeProjects.isNotEmpty,
          ),
        AnimatedSize(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeInOut,
          alignment: Alignment.topCenter,
          child: _isSearchVisible
              ? TaskSearchAndFiltersRow(
                  searchQuery: taskState.searchQuery,
                  parsedQuery: taskState.parsedSearchQuery,
                  onSearchChanged: taskState.setSearchQuery,
                  allTags: taskState.allTags,
                  allProjects: taskState.allProjects,
                  includeTags: taskState.includeTags,
                  excludeTags: taskState.excludeTags,
                  tagMatchMode: taskState.tagMatchMode,
                  includeProjects: taskState.includeProjects,
                  excludeProjects: taskState.excludeProjects,
                  projectMatchMode: taskState.projectMatchMode,
                  onOpenTags: () => _showTagSelector(context, taskState),
                  onOpenProjects: () =>
                      _showProjectSelector(context, taskState),
                  onClear: taskState.clearFilters,
                  onRemoveTag: taskState.toggleTag,
                  onRemoveExcludedTag: taskState.toggleExcludedTag,
                  onRemoveProject: taskState.toggleProject,
                  onRemoveExcludedProject: taskState.toggleExcludedProject,
                )
              : const SizedBox(width: double.infinity, height: 0),
        ),
        Expanded(child: _buildTaskBody(context, taskState)),
      ],
    );
  }

  PreferredSizeWidget _buildTopBar(BuildContext context, TaskState taskState) {
    final theme = Theme.of(context);
    final profileState = context.watch<ProfileState>();
    final currentProfile = profileState.currentProfile;
    final initials = (currentProfile?.name.isNotEmpty ?? false)
        ? currentProfile!.name[0].toUpperCase()
        : 'T';
    final activeCtx = taskState.activeContext;

    return AppBar(
      title: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => _ContextChip.showContextSheet(context, taskState),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text(
                  activeCtx != null ? activeCtx.name : 'Tasks',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Icon(Icons.arrow_drop_down, size: 20),
            ],
          ),
        ),
      ),
      leading: Builder(
        builder: (context) {
          return Padding(
            padding: const EdgeInsets.all(8),
            child: InkWell(
              borderRadius: BorderRadius.circular(50),
              onTap: () => Scaffold.of(context).openDrawer(),
              child: CircleAvatar(
                radius: 16,
                backgroundColor: theme.colorScheme.primaryContainer,
                foregroundColor: theme.colorScheme.onPrimaryContainer,
                child: Text(
                  initials,
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                  ),
                ),
              ),
            ),
          );
        },
      ),
      actions: [
        if (currentProfile?.serverUrl.isNotEmpty ?? false)
          IconButton(
            onPressed: taskState.isSyncing
                ? null
                : () async {
                    final error = await taskState.sync(currentProfile!);
                    if (!context.mounted) return;
                    final theme = Theme.of(context);
                    final isError = error != null;
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          error ?? 'Sync complete',
                          style: TextStyle(
                            color: isError
                                ? theme.colorScheme.onError
                                : theme.colorScheme.onPrimaryContainer,
                          ),
                        ),
                        backgroundColor: isError
                            ? theme.colorScheme.error
                            : theme.colorScheme.primaryContainer,
                      ),
                    );
                  },
            icon: RotationTransition(
              turns: _syncAnimController,
              child: const Icon(Icons.sync),
            ),
            tooltip: taskState.isSyncing ? 'Syncing...' : 'Sync',
          ),
      ],
    );
  }

  PreferredSizeWidget _buildSelectionBar(
    BuildContext context,
    TaskState taskState,
  ) {
    final count = taskState.selectedTaskUuids.length;
    final theme = Theme.of(context);

    return AppBar(
      backgroundColor: theme.colorScheme.primaryContainer,
      foregroundColor: theme.colorScheme.onPrimaryContainer,
      leading: IconButton(
        icon: const Icon(Icons.close),
        onPressed: taskState.clearSelection,
      ),
      title: Text(
        '$count selected',
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
      actions: [
        IconButton(
          icon: const Icon(Icons.check_circle_outline),
          tooltip: 'Mark Done',
          onPressed: () async {
            final error = await taskState.bulkMarkDone();
            if (!context.mounted) return;
            _showUndoSnack(
              context,
              error ?? '$count tasks completed',
              isError: error != null,
              onUndo: error == null ? taskState.undo : null,
            );
          },
        ),
        IconButton(
          icon: const Icon(Icons.delete_outline),
          tooltip: 'Delete',
          onPressed: () async {
            final error = await taskState.bulkDelete();
            if (!context.mounted) return;
            _showUndoSnack(
              context,
              error ?? '$count tasks deleted',
              isError: error != null,
              onUndo: error == null ? taskState.undo : null,
            );
          },
        ),
        const SizedBox(width: 8),
      ],
    );
  }

  Widget _buildTaskBody(BuildContext context, TaskState taskState) {
    final sourceTasks = taskState.displaySourceTasks;
    final filteredTasks = taskState.filteredTasks;

    if (taskState.error != null && sourceTasks.isEmpty) {
      return _InlineMessageState(
        icon: Icons.error_outline,
        title: 'Unable to load tasks',
        subtitle: taskState.error!,
        buttonText: 'Retry',
        onPressed: taskState.refreshPendingTasks,
      );
    }

    if (taskState.isLoading && sourceTasks.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

    if (sourceTasks.isEmpty && !taskState.usesExplicitStatusScope) {
      return _InlineMessageState(
        icon: Icons.task_alt,
        title: 'You\'re all caught up!',
        subtitle: _emptyStateSubtitle(taskState.queueView),
        buttonText: _emptyStateButtonText(taskState.queueView),
        onPressed: () {
          if (taskState.queueView == TaskQueueView.ready) {
            _showCreateSheet(context);
          } else {
            taskState.setQueueView(TaskQueueView.ready);
          }
        },
      );
    }

    if (filteredTasks.isEmpty) {
      return _InlineMessageState(
        icon: Icons.search_off,
        title: 'No matches found',
        subtitle: 'Try adjusting your filters or search query.',
        buttonText: 'Clear filters',
        onPressed: () {
          taskState.clearFilters();
        },
      );
    }

    return RefreshIndicator(
      onRefresh: taskState.refreshPendingTasks,
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverList(
            delegate: SliverChildBuilderDelegate(
              (context, index) => Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: TaskListItem(task: filteredTasks[index]),
              ),
              childCount: filteredTasks.length,
            ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 120)),
        ],
      ),
    );
  }

  Future<void> _showCreateSheet(BuildContext context) async {
    final taskState = context.read<TaskState>();
    if (taskState.currentProfileId == null) return;

    final ctx = taskState.activeContext;
    final wq = ctx != null && ctx.writeQuery.isNotEmpty
        ? parseWriteQuery(ctx.writeQuery)
        : null;
    final initialValues = wq != null
        ? TaskEditorInitialValues(
            project: wq.project,
            priority: wq.priority,
            tags: wq.tags.toList(),
          )
        : null;

    final result = await showTaskEditorSheet(
      context,
      initialValues: initialValues,
    );
    if (!context.mounted || result == null) return;

    final udaMap = {for (final uda in result.udas) uda.key: uda.value};
    final recurrence = result.recurrence ?? '';

    final error = await taskState.createTask(
      CreateTaskParams(
        description: result.description,
        status: TaskStatus.pending,
        project: result.project,
        priority: result.priority,
        tags: result.tags,
        due: result.due?.toUtc().toIso8601String(),
        wait: result.wait?.toUtc().toIso8601String(),
        scheduled: result.scheduled?.toUtc().toIso8601String(),
        until: result.until?.toUtc().toIso8601String(),
        recurrence: recurrence.isEmpty ? null : recurrence,
        udas: udaMap.entries
            .map((entry) => UdaPair(key: entry.key, value: entry.value))
            .toList(),
      ),
    );

    if (!context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(error ?? 'Task created')));
  }

  void _showUndoSnack(
    BuildContext context,
    String message, {
    required bool isError,
    Future<String?> Function()? onUndo,
  }) {
    final theme = Theme.of(context);
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError
            ? theme.colorScheme.error
            : theme.colorScheme.primaryContainer,
        behavior: SnackBarBehavior.floating,
        action: onUndo == null
            ? null
            : SnackBarAction(
                label: 'Undo',
                textColor: isError
                    ? theme.colorScheme.onError
                    : theme.colorScheme.onPrimaryContainer,
                onPressed: () => onUndo(),
              ),
      ),
    );
  }

  Future<void> _showProfileSwitcher(BuildContext context) async {
    final profileState = context.read<ProfileState>();
    final theme = Theme.of(context);

    final selected = await showModalBottomSheet<String>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 12),
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: theme.colorScheme.onSurfaceVariant.withValues(
                    alpha: 0.4,
                  ),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                'Switch Profile',
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 16),
              Expanded(
                child: ListView(
                  shrinkWrap: true,
                  children: profileState.profiles.map((profile) {
                    final isSelected =
                        profileState.currentProfileId == profile.id;
                    return ListTile(
                      leading: CircleAvatar(
                        backgroundColor: isSelected
                            ? theme.colorScheme.primary
                            : theme.colorScheme.surfaceContainerHighest,
                        foregroundColor: isSelected
                            ? theme.colorScheme.onPrimary
                            : theme.colorScheme.onSurfaceVariant,
                        child: Text(profile.name[0].toUpperCase()),
                      ),
                      title: Text(
                        profile.name,
                        style: TextStyle(
                          fontWeight: isSelected
                              ? FontWeight.bold
                              : FontWeight.normal,
                        ),
                      ),
                      trailing: isSelected
                          ? Icon(Icons.check, color: theme.colorScheme.primary)
                          : null,
                      onTap: () => Navigator.pop(context, profile.id),
                    );
                  }).toList(),
                ),
              ),
            ],
          ),
        );
      },
    );

    if (selected != null) {
      await profileState.setCurrentProfile(selected);
    }
  }

  Future<void> _showTagSelector(
    BuildContext context,
    TaskState taskState,
  ) async {
    await _showIncludeExcludeFilterSheet<String>(
      context,
      'Filter by Tags',
      taskState.allTags,
      initialInclude: taskState.includeTags,
      initialExclude: taskState.excludeTags,
      initialMode: taskState.tagMatchMode,
      modeLabel: 'Match mode',
      itemLabel: (tag) => tag,
      onApply: (include, exclude, mode) {
        taskState.setTagFilters(include: include, exclude: exclude, mode: mode);
      },
    );
  }

  Future<void> _showProjectSelector(
    BuildContext context,
    TaskState taskState,
  ) async {
    await _showIncludeExcludeFilterSheet<String>(
      context,
      'Filter by Projects',
      taskState.allProjects,
      initialInclude: taskState.includeProjects,
      initialExclude: taskState.excludeProjects,
      initialMode: taskState.projectMatchMode,
      modeLabel: 'Match mode',
      itemLabel: (project) => project,
      onApply: (include, exclude, mode) {
        taskState.setProjectFilters(
          include: include,
          exclude: exclude,
          mode: mode,
        );
      },
    );
  }

  Future<void> _showIncludeExcludeFilterSheet<T>(
    BuildContext context,
    String title,
    Set<T> allItems, {
    required Set<T> initialInclude,
    required Set<T> initialExclude,
    required FilterMatchMode initialMode,
    required String modeLabel,
    bool enableModeToggle = true,
    required String Function(T) itemLabel,
    required void Function(Set<T>, Set<T>, FilterMatchMode) onApply,
  }) async {
    final theme = Theme.of(context);
    final include = Set<T>.from(initialInclude);
    final exclude = Set<T>.from(initialExclude);
    final sortedItems = allItems.toList()
      ..sort(
        (a, b) =>
            itemLabel(a).toLowerCase().compareTo(itemLabel(b).toLowerCase()),
      );
    final applied = await showModalBottomSheet<_IncludeExcludeSelection<T>>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) {
        var mode = initialMode;
        var itemSearch = '';
        return StatefulBuilder(
          builder: (context, setModalState) {
            _FilterSelectionState stateFor(T item) {
              if (include.contains(item)) return _FilterSelectionState.include;
              if (exclude.contains(item)) return _FilterSelectionState.exclude;
              return _FilterSelectionState.none;
            }

            void cycleState(T item) {
              final current = stateFor(item);
              switch (current) {
                case _FilterSelectionState.none:
                  include.add(item);
                  exclude.remove(item);
                case _FilterSelectionState.include:
                  include.remove(item);
                  exclude.add(item);
                case _FilterSelectionState.exclude:
                  exclude.remove(item);
              }
            }

            final visibleItems = sortedItems.where((item) {
              if (itemSearch.isEmpty) return true;
              return itemLabel(
                item,
              ).toLowerCase().contains(itemSearch.toLowerCase());
            }).toList();

            final mediaQuery = MediaQuery.of(context);
            return AnimatedPadding(
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOut,
              padding: EdgeInsets.only(bottom: mediaQuery.viewInsets.bottom),
              child: SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      maxHeight: mediaQuery.size.height * 0.85,
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: theme.textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 16),
                        if (enableModeToggle) ...[
                          Row(
                            children: [
                              Text(
                                modeLabel,
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                              const Spacer(),
                              IconButton.outlined(
                                onPressed: () {
                                  setModalState(() {
                                    mode = mode == FilterMatchMode.and
                                        ? FilterMatchMode.or
                                        : FilterMatchMode.and;
                                  });
                                },
                                icon: const Icon(Icons.sync_alt),
                                tooltip: 'Toggle AND/OR',
                              ),
                              const SizedBox(width: 8),
                              Text(
                                mode.name.toUpperCase(),
                                style: theme.textTheme.labelLarge,
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                        ],
                        TextField(
                          decoration: const InputDecoration(
                            hintText: 'Search items...',
                            prefixIcon: Icon(Icons.search, size: 18),
                            isDense: true,
                          ),
                          onChanged: (value) {
                            setModalState(() {
                              itemSearch = value;
                            });
                          },
                        ),
                        const SizedBox(height: 10),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            Chip(
                              avatar: const Icon(Icons.add, size: 14),
                              label: const Text('Include'),
                              visualDensity: VisualDensity.compact,
                              backgroundColor:
                                  theme.colorScheme.primaryContainer,
                            ),
                            Chip(
                              avatar: const Icon(Icons.remove, size: 14),
                              label: const Text('Exclude'),
                              visualDensity: VisualDensity.compact,
                              backgroundColor: theme.colorScheme.errorContainer,
                            ),
                            Chip(
                              avatar: const Icon(
                                Icons.radio_button_unchecked,
                                size: 14,
                              ),
                              label: const Text('Off'),
                              visualDensity: VisualDensity.compact,
                            ),
                          ],
                        ),
                        if (allItems.isEmpty) ...[
                          const SizedBox(height: 16),
                          const Text('No items available'),
                        ] else ...[
                          const SizedBox(height: 16),
                          Flexible(
                            child: SingleChildScrollView(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'Tap each item to cycle include/exclude/off',
                                    style: theme.textTheme.bodySmall?.copyWith(
                                      color: theme.colorScheme.onSurfaceVariant,
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  if (visibleItems.isEmpty)
                                    const Text('No items match your search')
                                  else
                                    Wrap(
                                      spacing: 8,
                                      runSpacing: 8,
                                      children: visibleItems.map((item) {
                                        final state = stateFor(item);
                                        final isActive =
                                            state != _FilterSelectionState.none;
                                        final avatar = switch (state) {
                                          _FilterSelectionState.include =>
                                            const Icon(Icons.add, size: 14),
                                          _FilterSelectionState.exclude =>
                                            const Icon(Icons.remove, size: 14),
                                          _FilterSelectionState.none =>
                                            const Icon(
                                              Icons.radio_button_unchecked,
                                              size: 14,
                                            ),
                                        };
                                        final selectedColor = switch (state) {
                                          _FilterSelectionState.include =>
                                            theme.colorScheme.primaryContainer,
                                          _FilterSelectionState.exclude =>
                                            theme.colorScheme.errorContainer,
                                          _FilterSelectionState.none =>
                                            theme
                                                .colorScheme
                                                .surfaceContainerHighest,
                                        };
                                        return FilterChip(
                                          avatar: avatar,
                                          label: Text(itemLabel(item)),
                                          selected: isActive,
                                          selectedColor: selectedColor,
                                          onSelected: (_) {
                                            setModalState(() {
                                              cycleState(item);
                                            });
                                          },
                                        );
                                      }).toList(),
                                    ),
                                ],
                              ),
                            ),
                          ),
                        ],
                        const SizedBox(height: 16),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          alignment: WrapAlignment.end,
                          children: [
                            TextButton(
                              onPressed: () {
                                setModalState(() {
                                  include.clear();
                                  exclude.clear();
                                });
                              },
                              child: const Text('Clear'),
                            ),
                            if (visibleItems.isNotEmpty)
                              TextButton(
                                onPressed: () {
                                  setModalState(() {
                                    for (final item in visibleItems) {
                                      include.add(item);
                                      exclude.remove(item);
                                    }
                                  });
                                },
                                child: const Text('Include visible'),
                              ),
                            if (visibleItems.isNotEmpty)
                              TextButton(
                                onPressed: () {
                                  setModalState(() {
                                    for (final item in visibleItems) {
                                      exclude.add(item);
                                      include.remove(item);
                                    }
                                  });
                                },
                                child: const Text('Exclude visible'),
                              ),
                            FilledButton(
                              onPressed: () => Navigator.pop(
                                context,
                                _IncludeExcludeSelection<T>(
                                  include: Set<T>.from(include),
                                  exclude: Set<T>.from(exclude),
                                  mode: mode,
                                ),
                              ),
                              child: const Text('Apply'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    );

    if (applied != null) {
      onApply(applied.include, applied.exclude, applied.mode);
    }
  }
}

class _IncludeExcludeSelection<T> {
  const _IncludeExcludeSelection({
    required this.include,
    required this.exclude,
    required this.mode,
  });

  final Set<T> include;
  final Set<T> exclude;
  final FilterMatchMode mode;
}

enum _FilterSelectionState { none, include, exclude }

class TaskSearchAndFiltersRow extends StatefulWidget {
  const TaskSearchAndFiltersRow({
    super.key,
    required this.searchQuery,
    required this.parsedQuery,
    required this.onSearchChanged,
    required this.allTags,
    required this.allProjects,
    required this.includeTags,
    required this.excludeTags,
    required this.tagMatchMode,
    required this.includeProjects,
    required this.excludeProjects,
    required this.projectMatchMode,
    required this.onOpenTags,
    required this.onOpenProjects,
    required this.onClear,
    required this.onRemoveTag,
    required this.onRemoveExcludedTag,
    required this.onRemoveProject,
    required this.onRemoveExcludedProject,
  });

  final String searchQuery;
  final TaskQuery parsedQuery;
  final ValueChanged<String> onSearchChanged;
  final Set<String> allTags;
  final Set<String> allProjects;
  final Set<String> includeTags;
  final Set<String> excludeTags;
  final FilterMatchMode tagMatchMode;
  final Set<String> includeProjects;
  final Set<String> excludeProjects;
  final FilterMatchMode projectMatchMode;
  final VoidCallback onOpenTags;
  final VoidCallback onOpenProjects;
  final VoidCallback onClear;
  final ValueChanged<String> onRemoveTag;
  final ValueChanged<String> onRemoveExcludedTag;
  final ValueChanged<String> onRemoveProject;
  final ValueChanged<String> onRemoveExcludedProject;

  @override
  State<TaskSearchAndFiltersRow> createState() => _SearchAndFiltersRowState();
}

class _SearchAndFiltersRowState extends State<TaskSearchAndFiltersRow> {
  static const int _maxSuggestionRows = 6;

  late TextEditingController _searchController;
  List<TaskQuerySuggestion> _suggestions = const [];
  bool _isUpdatingController = false;
  Set<String> _stableTags = const {};
  Set<String> _stableProjects = const {};

  static const List<String> _queryExamples = [
    '+home project:work',
    'status:completed',
    'due.before:today',
    '+ready -blocked',
  ];

  void _applyExample(String suggestion) {
    _isUpdatingController = true;
    _searchController.text = suggestion;
    _searchController.selection = TextSelection.collapsed(
      offset: suggestion.length,
    );
    _isUpdatingController = false;
    _refreshSuggestions();
    widget.onSearchChanged(suggestion);
  }

  void _applySuggestion(TaskQuerySuggestion suggestion) {
    final completion = TaskQueryAutocomplete.applySuggestionToValue(
      value: _searchController.value,
      suggestion: suggestion,
    );
    _isUpdatingController = true;
    _searchController.value = TextEditingValue(
      text: completion.text,
      selection: TextSelection.collapsed(offset: completion.selectionOffset),
    );
    _isUpdatingController = false;
    _refreshSuggestions();
    widget.onSearchChanged(completion.text);
  }

  @override
  void initState() {
    super.initState();
    _searchController = TextEditingController(text: widget.searchQuery);
    _searchController.addListener(_handleSearchControllerChanged);
    _captureStableSuggestionSources();
    _suggestions = _buildSuggestions();
  }

  @override
  void didUpdateWidget(covariant TaskSearchAndFiltersRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    _captureStableSuggestionSources();
    if (widget.searchQuery != _searchController.text) {
      _isUpdatingController = true;
      _searchController.value = _searchController.value.copyWith(
        text: widget.searchQuery,
        selection: TextSelection.collapsed(offset: widget.searchQuery.length),
      );
      _isUpdatingController = false;
      _refreshSuggestions();
    } else if (!setEquals(widget.allTags, oldWidget.allTags) ||
        !setEquals(widget.allProjects, oldWidget.allProjects)) {
      _refreshSuggestions();
    }
  }

  void _handleSearchControllerChanged() {
    if (_isUpdatingController) return;
    _refreshSuggestions();
  }

  void _refreshSuggestions() {
    final suggestions = _buildSuggestions();
    if (!mounted) {
      _suggestions = suggestions;
      return;
    }
    setState(() {
      _suggestions = suggestions;
    });
  }

  List<TaskQuerySuggestion> _buildSuggestions() {
    final effectiveTags = widget.allTags.isNotEmpty
        ? widget.allTags
        : _stableTags;
    final effectiveProjects = widget.allProjects.isNotEmpty
        ? widget.allProjects
        : _stableProjects;
    final selectionOffset = _searchController.selection.baseOffset < 0
        ? _searchController.text.length
        : _searchController.selection.baseOffset;
    return TaskQueryAutocomplete.suggestionsFor(
      query: _searchController.text,
      selectionOffset: selectionOffset,
      tags: effectiveTags,
      projects: effectiveProjects,
      limit: _maxSuggestionRows,
    );
  }

  void _captureStableSuggestionSources() {
    if (widget.allTags.isNotEmpty) {
      _stableTags = Set<String>.from(widget.allTags);
    }
    if (widget.allProjects.isNotEmpty) {
      _stableProjects = Set<String>.from(widget.allProjects);
    }
  }

  @override
  void dispose() {
    _searchController.removeListener(_handleSearchControllerChanged);
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hasFilters =
        widget.includeTags.isNotEmpty ||
        widget.excludeTags.isNotEmpty ||
        widget.includeProjects.isNotEmpty ||
        widget.excludeProjects.isNotEmpty;
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _searchController,
            onChanged: widget.onSearchChanged,
            decoration: InputDecoration(
              hintText: 'Search tasks...',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: _searchController.text.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.clear),
                      onPressed: () {
                        _searchController.clear();
                        widget.onSearchChanged('');
                      },
                    ),
            ),
          ),
          if (_searchController.text.isNotEmpty) ...[
            if (_suggestions.isNotEmpty) ...[
              const SizedBox(height: 8),
              _QuerySuggestionDropdown(
                suggestions: _suggestions,
                iconForType: _suggestionIcon,
                onSelected: _applySuggestion,
              ),
            ],
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: widget.parsedQuery.hasErrors
                    ? theme.colorScheme.errorContainer
                    : theme.colorScheme.secondaryContainer.withValues(
                        alpha: 0.7,
                      ),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                children: [
                  Icon(
                    widget.parsedQuery.hasErrors
                        ? Icons.error_outline
                        : Icons.rule,
                    size: 16,
                    color: widget.parsedQuery.hasErrors
                        ? theme.colorScheme.onErrorContainer
                        : theme.colorScheme.onSecondaryContainer,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      widget.parsedQuery.issues.isNotEmpty
                          ? widget.parsedQuery.issues.first.message
                          : widget.parsedQuery.isAdvanced
                          ? 'Advanced query parsed (${widget.parsedQuery.termCount} terms)'
                          : 'Text search mode',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: widget.parsedQuery.hasErrors
                            ? theme.colorScheme.onErrorContainer
                            : theme.colorScheme.onSecondaryContainer,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ] else ...[
            const SizedBox(height: 8),
            Text(
              'Examples',
              style: theme.textTheme.labelLarge?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: _queryExamples.map((example) {
                return ActionChip(
                  label: Text(example),
                  onPressed: () => _applyExample(example),
                );
              }).toList(),
            ),
          ],
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              ActionChip(
                avatar: const Icon(Icons.label_outline, size: 16),
                label: Text(
                  widget.includeTags.isEmpty && widget.excludeTags.isEmpty
                      ? 'Tags'
                      : 'Tags (${widget.includeTags.length}/${widget.excludeTags.length})',
                ),
                onPressed: widget.onOpenTags,
                backgroundColor:
                    widget.includeTags.isNotEmpty ||
                        widget.excludeTags.isNotEmpty
                    ? theme.colorScheme.primaryContainer
                    : null,
              ),
              Icon(
                widget.tagMatchMode == FilterMatchMode.and
                    ? Icons.call_merge
                    : Icons.alt_route,
                size: 16,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              ActionChip(
                avatar: const Icon(Icons.folder_outlined, size: 16),
                label: Text(
                  widget.includeProjects.isEmpty &&
                          widget.excludeProjects.isEmpty
                      ? 'Projects'
                      : 'Projects (${widget.includeProjects.length}/${widget.excludeProjects.length})',
                ),
                onPressed: widget.onOpenProjects,
                backgroundColor:
                    widget.includeProjects.isNotEmpty ||
                        widget.excludeProjects.isNotEmpty
                    ? theme.colorScheme.primaryContainer
                    : null,
              ),
              Icon(
                widget.projectMatchMode == FilterMatchMode.and
                    ? Icons.call_merge
                    : Icons.alt_route,
                size: 16,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ],
          ),
          if (hasFilters || _searchController.text.isNotEmpty)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: widget.onClear,
                child: const Text('Clear'),
              ),
            ),
          if (hasFilters) ...[
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  ...widget.includeTags.map(
                    (tag) => InputChip(
                      avatar: const Icon(Icons.add, size: 14),
                      label: Text(tag, style: const TextStyle(fontSize: 12)),
                      onDeleted: () => widget.onRemoveTag(tag),
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                  ...widget.excludeTags.map(
                    (tag) => InputChip(
                      avatar: const Icon(Icons.remove, size: 14),
                      label: Text(tag, style: const TextStyle(fontSize: 12)),
                      onDeleted: () => widget.onRemoveExcludedTag(tag),
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                  ...widget.includeProjects.map(
                    (project) => InputChip(
                      avatar: const Icon(Icons.add, size: 14),
                      label: Text(
                        project,
                        style: const TextStyle(fontSize: 12),
                      ),
                      onDeleted: () => widget.onRemoveProject(project),
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                  ...widget.excludeProjects.map(
                    (project) => InputChip(
                      avatar: const Icon(Icons.folder_outlined, size: 14),
                      label: Text(
                        project,
                        style: const TextStyle(fontSize: 12),
                      ),
                      onDeleted: () => widget.onRemoveExcludedProject(project),
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  IconData _suggestionIcon(TaskQuerySuggestionType type) {
    return switch (type) {
      TaskQuerySuggestionType.operator => Icons.rule,
      TaskQuerySuggestionType.field => Icons.short_text,
      TaskQuerySuggestionType.value => Icons.label_outline,
      TaskQuerySuggestionType.flag => Icons.flag_outlined,
      TaskQuerySuggestionType.date => Icons.event_outlined,
    };
  }
}

class _QuerySuggestionDropdown extends StatelessWidget {
  const _QuerySuggestionDropdown({
    required this.suggestions,
    required this.iconForType,
    required this.onSelected,
  });

  final List<TaskQuerySuggestion> suggestions;
  final IconData Function(TaskQuerySuggestionType type) iconForType;
  final ValueChanged<TaskQuerySuggestion> onSelected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      elevation: 2,
      color: theme.colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 280),
        child: ListView.separated(
          padding: EdgeInsets.zero,
          shrinkWrap: true,
          itemCount: suggestions.length,
          separatorBuilder: (context, index) => Divider(
            height: 1,
            color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
          ),
          itemBuilder: (context, index) {
            final suggestion = suggestions[index];
            return InkWell(
              onTap: () => onSelected(suggestion),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                child: Row(
                  children: [
                    Icon(
                      iconForType(suggestion.type),
                      size: 18,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            suggestion.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            suggestion.detail,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Icon(
                      Icons.north_west,
                      size: 14,
                      color: theme.colorScheme.onSurfaceVariant.withValues(
                        alpha: 0.8,
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _BroadResultsBar extends StatelessWidget {
  const _BroadResultsBar({
    required this.resultCount,
    required this.isSearchVisible,
    required this.hasActiveFilters,
    required this.onToggleSearch,
  });

  final int resultCount;
  final bool isSearchVisible;
  final bool hasActiveFilters;
  final VoidCallback onToggleSearch;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Row(
        children: [
          Icon(Icons.filter_list, size: 18, color: theme.colorScheme.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Matching tasks ($resultCount)',
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w600,
                color: theme.colorScheme.onSurface,
              ),
            ),
          ),
          IconButton(
            onPressed: onToggleSearch,
            icon: Stack(
              children: [
                Icon(isSearchVisible ? Icons.search_off : Icons.search),
                if (hasActiveFilters)
                  Positioned(
                    right: 0,
                    top: 0,
                    child: Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primary,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
              ],
            ),
            color: isSearchVisible
                ? theme.colorScheme.primary
                : theme.colorScheme.onSurfaceVariant,
            tooltip: 'Toggle query',
          ),
        ],
      ),
    );
  }
}

class _QueueViewAndSearchToggleRow extends StatelessWidget {
  const _QueueViewAndSearchToggleRow({
    required this.selected,
    required this.readyCount,
    required this.waitingCount,
    required this.scheduledCount,
    required this.onSelected,
    required this.isSearchVisible,
    required this.onToggleSearch,
    required this.hasActiveFilters,
  });

  final TaskQueueView selected;
  final int readyCount;
  final int waitingCount;
  final int scheduledCount;
  final ValueChanged<TaskQueueView> onSelected;
  final bool isSearchVisible;
  final VoidCallback onToggleSearch;
  final bool hasActiveFilters;

  String _formatCount(int count) {
    if (count < 1000) return '$count';
    if (count < 1000000) {
      final value = count / 1000;
      final text = value >= 100
          ? value.toStringAsFixed(0)
          : value.toStringAsFixed(1);
      return '${text.endsWith('.0') ? text.substring(0, text.length - 2) : text}k';
    }
    final value = count / 1000000;
    final text = value >= 100
        ? value.toStringAsFixed(0)
        : value.toStringAsFixed(1);
    return '${text.endsWith('.0') ? text.substring(0, text.length - 2) : text}M';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    Widget chip(TaskQueueView view, String label, int count, IconData icon) {
      final active = selected == view;
      return ChoiceChip(
        avatar: Icon(icon, size: 16),
        label: Text('$label (${_formatCount(count)})'),
        selected: active,
        onSelected: (_) => onSelected(view),
        showCheckmark: false,
        side: BorderSide(
          color: active
              ? Colors.transparent
              : theme.colorScheme.outline.withValues(alpha: 0.3),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Row(
        children: [
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  chip(
                    TaskQueueView.ready,
                    'Ready',
                    readyCount,
                    Icons.task_alt,
                  ),
                  const SizedBox(width: 8),
                  chip(
                    TaskQueueView.waiting,
                    'Waiting',
                    waitingCount,
                    Icons.hourglass_empty,
                  ),
                  const SizedBox(width: 8),
                  chip(
                    TaskQueueView.scheduled,
                    'Scheduled',
                    scheduledCount,
                    Icons.schedule,
                  ),
                ],
              ),
            ),
          ),
          IconButton(
            onPressed: onToggleSearch,
            icon: Stack(
              children: [
                Icon(isSearchVisible ? Icons.search_off : Icons.search),
                if (hasActiveFilters)
                  Positioned(
                    right: 0,
                    top: 0,
                    child: Container(
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primary,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      width: 8,
                      height: 8,
                    ),
                  ),
              ],
            ),
            color: isSearchVisible || hasActiveFilters
                ? theme.colorScheme.primary
                : theme.colorScheme.onSurfaceVariant,
            tooltip: 'Toggle query',
          ),
        ],
      ),
    );
  }
}

class _ContextChip {
  static void showContextSheet(BuildContext context, TaskState taskState) {
    final theme = Theme.of(context);

    showModalBottomSheet<void>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            final contexts = taskState.contexts;
            final activeId = taskState.activeContext?.id;

            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 12, 24, 16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            'Context',
                            style: theme.textTheme.titleLarge?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.add),
                          tooltip: 'Define context',
                          onPressed: () async {
                            if (await showDefineDialog(context, taskState)) {
                              setModalState(() {});
                            }
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    const Divider(),
                    if (contexts.isEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 24),
                        child: Center(
                          child: Column(
                            children: [
                              Icon(
                                Icons.filter_alt_outlined,
                                size: 48,
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                              const SizedBox(height: 8),
                              Text(
                                'No contexts defined',
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                              const SizedBox(height: 16),
                              TextButton.icon(
                                onPressed: () async {
                                  if (await showDefineDialog(
                                    context,
                                    taskState,
                                  )) {
                                    setModalState(() {});
                                  }
                                },
                                icon: const Icon(Icons.add),
                                label: const Text('Define one'),
                              ),
                            ],
                          ),
                        ),
                      )
                    else
                      Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Flexible(
                            child: SingleChildScrollView(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: contexts
                                    .map(
                                      (ctx) => _ContextListTile(
                                        taskContext: ctx,
                                        isActive: ctx.id == activeId,
                                        theme: theme,
                                        taskState: taskState,
                                        setModalState: setModalState,
                                      ),
                                    )
                                    .toList(),
                              ),
                            ),
                          ),
                          const Divider(),
                          ListTile(
                            leading: Icon(
                              activeId == null
                                  ? Icons.radio_button_checked
                                  : Icons.radio_button_unchecked,
                              color: activeId == null
                                  ? theme.colorScheme.primary
                                  : theme.colorScheme.onSurfaceVariant,
                            ),
                            title: Text(
                              'None (clear context)',
                              style: TextStyle(
                                fontWeight: activeId == null
                                    ? FontWeight.bold
                                    : FontWeight.normal,
                                color: activeId == null
                                    ? theme.colorScheme.primary
                                    : null,
                              ),
                            ),
                            onTap: () {
                              taskState.clearActiveContext();
                              Navigator.pop(context);
                            },
                          ),
                        ],
                      ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  static Future<bool> showDefineDialog(
    BuildContext context,
    TaskState taskState,
  ) async {
    final nameController = TextEditingController();
    final queryController = TextEditingController();
    final writeController = TextEditingController();

    queryController.text = taskState.searchQuery;

    var didDefine = false;

    await showDialog<void>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: const Text(
            'Define Context',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameController,
                autofocus: true,
                decoration: const InputDecoration(
                  hintText: 'e.g. work, home, study...',
                  prefixIcon: Icon(Icons.label_outline),
                ),
                textCapitalization: TextCapitalization.words,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: queryController,
                decoration: const InputDecoration(
                  hintText: 'Read filter, e.g. +work or +freelance',
                  prefixIcon: Icon(Icons.filter_alt_outlined),
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: writeController,
                decoration: const InputDecoration(
                  hintText: 'Write default, e.g. +work project:Work',
                  prefixIcon: Icon(Icons.edit_outlined),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                final name = nameController.text.trim();
                final query = queryController.text.trim();
                final write = writeController.text.trim();
                if (name.isEmpty) return;
                taskState.defineContext(name, query, writeQuery: write);
                didDefine = true;
                Navigator.pop(ctx);
              },
              child: const Text('Save'),
            ),
          ],
        );
      },
    );
    nameController.dispose();
    queryController.dispose();
    writeController.dispose();
    return didDefine;
  }
}

class _ContextListTile extends StatelessWidget {
  const _ContextListTile({
    required this.taskContext,
    required this.isActive,
    required this.theme,
    required this.taskState,
    required this.setModalState,
  });

  final TaskContext taskContext;
  final bool isActive;
  final ThemeData theme;
  final TaskState taskState;
  final void Function(void Function()) setModalState;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(
        isActive ? Icons.radio_button_checked : Icons.radio_button_unchecked,
        color: isActive
            ? theme.colorScheme.primary
            : theme.colorScheme.onSurfaceVariant,
      ),
      title: Text(
        taskContext.name,
        style: TextStyle(
          fontWeight: isActive ? FontWeight.bold : FontWeight.normal,
          color: isActive ? theme.colorScheme.primary : null,
        ),
      ),
      subtitle:
          taskContext.searchQuery.isNotEmpty ||
              taskContext.writeQuery.isNotEmpty
          ? Text(
              '${taskContext.searchQuery.isNotEmpty ? 'read: ${taskContext.searchQuery}' : ''}${taskContext.searchQuery.isNotEmpty && taskContext.writeQuery.isNotEmpty ? '\n' : ''}${taskContext.writeQuery.isNotEmpty ? 'write: ${taskContext.writeQuery}' : ''}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            )
          : null,
      trailing: isActive
          ? TextButton(
              onPressed: () {
                taskState.clearActiveContext();
                Navigator.pop(context);
              },
              child: const Text('Clear'),
            )
          : null,
      onTap: () {
        taskState.setActiveContext(taskContext.id);
        Navigator.pop(context);
      },
      onLongPress: () {
        _showContextOptions(context);
      },
    );
  }

  void _showContextOptions(BuildContext parentContext) {
    final ts = taskState;

    showModalBottomSheet<void>(
      context: parentContext,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 12),
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: theme.colorScheme.onSurfaceVariant.withValues(
                    alpha: 0.4,
                  ),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 16),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        taskContext.name,
                        style: theme.textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 24),
                leading: Icon(
                  Icons.edit_outlined,
                  color: theme.colorScheme.primary,
                ),
                title: const Text(
                  'Edit',
                  style: TextStyle(fontWeight: FontWeight.w500),
                ),
                onTap: () {
                  Navigator.pop(context);
                  _showEditDialog(parentContext);
                },
              ),
              ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 24),
                leading: Icon(
                  Icons.delete_outline,
                  color: theme.colorScheme.error,
                ),
                title: Text(
                  'Delete',
                  style: TextStyle(
                    fontWeight: FontWeight.w500,
                    color: theme.colorScheme.error,
                  ),
                ),
                onTap: () async {
                  Navigator.pop(context);
                  await ts.deleteContext(taskContext.id);
                  if (parentContext.mounted) {
                    Navigator.of(parentContext).pop();
                  }
                },
              ),
              const SizedBox(height: 16),
            ],
          ),
        );
      },
    );
  }

  Future<void> _showEditDialog(BuildContext parentContext) async {
    final nameController = TextEditingController(text: taskContext.name);
    final queryController = TextEditingController(
      text: taskContext.searchQuery,
    );
    final writeController = TextEditingController(text: taskContext.writeQuery);

    nameController.selection = TextSelection(
      baseOffset: 0,
      extentOffset: nameController.text.length,
    );

    final result = await showDialog<Map<String, String>>(
      context: parentContext,
      builder: (ctx) {
        return AlertDialog(
          title: const Text(
            'Edit context',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameController,
                autofocus: true,
                decoration: const InputDecoration(
                  hintText: 'Context name',
                  prefixIcon: Icon(Icons.label_outline),
                ),
                textCapitalization: TextCapitalization.words,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: queryController,
                decoration: const InputDecoration(
                  hintText: 'Read filter, e.g. +work or +freelance',
                  prefixIcon: Icon(Icons.filter_alt_outlined),
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: writeController,
                decoration: const InputDecoration(
                  hintText: 'Write default, e.g. +work project:Work',
                  prefixIcon: Icon(Icons.edit_outlined),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                final name = nameController.text.trim();
                final query = queryController.text.trim();
                final write = writeController.text.trim();
                if (name.isEmpty) return;
                Navigator.pop(ctx, {
                  'name': name,
                  'query': query,
                  'write': write,
                });
              },
              child: const Text('Save'),
            ),
          ],
        );
      },
    );
    nameController.dispose();
    queryController.dispose();
    writeController.dispose();
    if (result != null) {
      taskState.updateContext(
        taskContext.id,
        result['name'] ?? taskContext.name,
        result['query'] ?? taskContext.searchQuery,
        writeQuery: result['write'] ?? taskContext.writeQuery,
      );
      setModalState(() {});
    }
  }
}

class _NoProfileState extends StatelessWidget {
  const _NoProfileState();

  @override
  Widget build(BuildContext context) {
    return _InlineMessageState(
      icon: Icons.account_circle_outlined,
      title: 'No profile selected',
      subtitle: 'Select or create a profile to start managing tasks.',
      buttonText: 'Open Menu',
      onPressed: () => Scaffold.of(context).openDrawer(),
    );
  }
}

class _InlineMessageState extends StatelessWidget {
  const _InlineMessageState({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.buttonText,
    required this.onPressed,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final String buttonText;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: theme.colorScheme.primaryContainer.withValues(
                  alpha: 0.5,
                ),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, size: 64, color: theme.colorScheme.primary),
            ),
            const SizedBox(height: 24),
            Text(
              title,
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.bold,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              subtitle,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 32),
            FilledButton.tonal(
              onPressed: onPressed,
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(
                  horizontal: 32,
                  vertical: 16,
                ),
              ),
              child: Text(buttonText),
            ),
          ],
        ),
      ),
    );
  }
}
