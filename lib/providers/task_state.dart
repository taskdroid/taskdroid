import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:taskdroid/models/filter_tab.dart';
import 'package:taskdroid/models/profile.dart';
import 'package:taskdroid/models/task_context.dart';
import 'package:taskdroid/services/calendar_service.dart';
import 'package:taskdroid/services/profile_storage.dart';
import 'package:taskdroid/services/sync_isolate_service.dart';
import 'package:taskdroid/services/task_context_service.dart';
import 'package:taskdroid/services/task_filter_service.dart';
import 'package:taskdroid/services/task_queue_service.dart';
import 'package:taskdroid/services/task_repository.dart';
import 'package:taskdroid/services/task_selection_service.dart';
import 'package:taskdroid/services/task_tab_service.dart';
import 'package:taskdroid/services/task_query_language.dart';
import 'package:taskdroid/src/rust/api.dart';

class TaskState extends ChangeNotifier {
  final TaskRepository _repo = TaskRepository();
  final TaskFilterService _filterService = TaskFilterService();
  final TaskTabService _tabService = TaskTabService();
  final TaskContextService _ctxService = TaskContextService();
  final TaskSelectionService _selectionService = TaskSelectionService();
  final TaskQueueService _queueService = TaskQueueService();
  final CalendarService _calendarService = CalendarService();
  final SyncIsolateService _syncService = SyncIsolateService();

  bool _isSyncing = false;
  String? _currentProfileId;
  bool _isCalendarSyncEnabled = false;
  Timer? _debounceFilterTimer;

  TaskManager? get taskManager => _repo.taskManager;
  List<TaskView> get pendingTasks => _repo.readyTasks;
  List<TaskView> get waitingTasks => _repo.waitingTasks;
  List<TaskView> get scheduledTasks => _repo.scheduledTasks;
  TaskQueueView get queueView => _queueService.queueView;
  List<TaskView> get currentViewTasks => _sourceTasksForCurrentView();
  bool get isLoading => _repo.isLoading;
  bool get isSyncing => _isSyncing;
  String? get error => _repo.error;
  String get searchQuery => _filterService.searchQuery;
  TaskQuery get parsedSearchQuery =>
      _filterService.parseQuery(effectiveSearchQuery);
  Set<String> get selectedTags => includeTags;
  Set<String> get selectedProjects => includeProjects;
  Set<String> get includeTags => _filterService.includeTags;
  Set<String> get excludeTags => _filterService.excludeTags;
  FilterMatchMode get tagMatchMode => _filterService.tagMatchMode;
  Set<String> get includeProjects => _filterService.includeProjects;
  Set<String> get excludeProjects => _filterService.excludeProjects;
  FilterMatchMode get projectMatchMode => _filterService.projectMatchMode;
  List<FilterTab> get filterTabs => _tabService.filterTabs;
  String? get currentProfileId => _currentProfileId;
  Set<String> get selectedTaskUuids => _selectionService.selectedUuids;
  bool get isSelectionMode => _selectionService.isNotEmpty;

  bool get usesExplicitStatusScope =>
      _filterService.parseQuery(effectiveSearchQuery).usesExplicitStatusScope;
  List<TaskView> get displaySourceTasks =>
      usesExplicitStatusScope ? _repo.allTasks : _sourceTasksForCurrentView();

  FilterTab? get currentTab => _tabService.currentTab();

  List<TaskContext> get contexts => _ctxService.contexts;
  TaskContext? get activeContext => _ctxService.activeContext;
  bool get hasActiveContext => _ctxService.activeContext != null;

  String get effectiveSearchQuery {
    final contextQuery = _ctxService.activeContext?.searchQuery ?? '';
    final userQuery = _buildFilterQuery();
    if (contextQuery.isEmpty) return userQuery;
    if (userQuery.isEmpty) return contextQuery;
    return '($contextQuery) $userQuery';
  }

  Set<String> get allTags => _repo.allTags;
  Set<String> get allProjects => _repo.allProjects;

  Future<void> loadProfile(Profile profile) async {
    if (_repo.taskManager != null && _currentProfileId == profile.id) {
      if (_repo.readyTasks.isEmpty && !_repo.isLoading) {
        await Future.wait([
          refreshPendingTasks(),
          _repo.refreshAutocompleteData(),
        ]);
      }
      return;
    }

    if (_repo.isLoading && _currentProfileId == profile.id) {
      return;
    }

    _currentProfileId = profile.id;
    _isCalendarSyncEnabled = profile.calendarSync;
    notifyListeners();

    try {
      final dbDir = await resolveProfileStorageDir(profile);

      await _repo.loadProfile(profile.id, dbDir.path, profile.recurrenceLimit);

      await _tabService.loadTabs(profile.id, _filterService);
      await _loadContexts(profile.id);

      await Future.wait([
        refreshPendingTasks(),
        _repo.refreshAutocompleteData(),
      ]);
    } catch (e) {
      debugPrint('Failed to load profile: $e');
      notifyListeners();
    }
  }

  Future<void> refreshPendingTasks() async {
    await _repo.refreshPendingTasks(effectiveSearchQuery);
    _filterService.invalidateCache();
    notifyListeners();
  }

  List<TaskView> get filteredTasks => _filterService.getFilteredTasks(
    allTasks: _repo.allTasks,
    readyTasks: _repo.readyTasks,
    waitingTasks: _repo.waitingTasks,
    scheduledTasks: _repo.scheduledTasks,
    queueView: _queueService.queueView,
    effectiveSearchQuery: effectiveSearchQuery,
  );

  Future<void> refreshAutocompleteData() async {
    await _repo.refreshAutocompleteData();
    notifyListeners();
  }

  String _buildFilterQuery() => _filterService.buildFilterQuery();

  @visibleForTesting
  bool matchesTaskFilters(TaskView task) =>
      _filterService.matchesTaskFilters(task, DateTime.now().toUtc());

  void setQueueView(TaskQueueView view) {
    if (_queueService.queueView == view) return;
    _queueService.setQueueView(view);
    _filterService.invalidateCache();
    notifyListeners();
  }

  List<TaskView> _sourceTasksForCurrentView() =>
      _queueService.sourceTasksForView(
        _repo.readyTasks,
        _repo.waitingTasks,
        _repo.scheduledTasks,
      );

  TaskView? findTaskByUuid(String uuid) => _repo.findTaskByUuid(uuid);

  Future<TaskView?> getTaskByUuid(String uuid) async =>
      _repo.getTaskByUuid(uuid);

  List<TaskView> get dependencyCandidates => _repo.dependencyCandidates;

  Future<String?> createTask(CreateTaskParams params) async {
    final result = await _repo.createTask(params);
    if (result.error != null) return result.error;

    await refreshPendingTasks();
    await refreshAutocompleteData();

    if (_isCalendarSyncEnabled && result.uuid != null) {
      final newTask = await _repo.getTaskByUuid(result.uuid!);
      if (newTask != null) {
        try {
          await _calendarService.syncTask(newTask);
        } catch (e) {
          return 'Calendar sync failed.';
        }
      }
    }
    return null;
  }

  Future<String?> markTaskDone(String uuid) async {
    final result = await _repo.markTaskDone(uuid);
    if (result != null) return result;
    if (_isCalendarSyncEnabled) {
      try {
        await _calendarService.deleteTask(uuid);
      } catch (e) {
        return 'Calendar sync failed.';
      }
    }
    return null;
  }

  Future<String?> deleteTask(String uuid) async {
    final result = await _repo.deleteTask(uuid);
    if (result != null) return result;
    if (_isCalendarSyncEnabled) {
      try {
        await _calendarService.deleteTask(uuid);
      } catch (e) {
        return 'Calendar sync failed.';
      }
    }
    return null;
  }

  Future<String?> deleteTaskSingle(String uuid) async {
    final result = await _repo.deleteTaskSingle(uuid);
    if (result != null) return result;
    if (_isCalendarSyncEnabled) {
      try {
        await _calendarService.deleteTask(uuid);
      } catch (e) {
        return 'Calendar sync failed.';
      }
    }
    await refreshPendingTasks();
    await refreshAutocompleteData();
    return null;
  }

  Future<String?> deleteTaskSeries(String uuid) async {
    final result = await _repo.deleteTaskSeries(uuid);
    if (result != null) return result;
    if (_isCalendarSyncEnabled) {
      try {
        await _calendarService.deleteTask(uuid);
      } catch (e) {
        return 'Calendar sync failed.';
      }
    }
    await refreshPendingTasks();
    await refreshAutocompleteData();
    return null;
  }

  Future<String?> markTaskDoneSingle(String uuid) async {
    final result = await _repo.markTaskDoneSingle(uuid);
    if (result != null) return result;
    if (_isCalendarSyncEnabled) {
      try {
        await _calendarService.deleteTask(uuid);
      } catch (e) {
        return 'Calendar sync failed.';
      }
    }
    await refreshPendingTasks();
    await refreshAutocompleteData();
    return null;
  }

  Future<String?> updateTask(String uuid, UpdateTaskParams params) async {
    final result = await _repo.updateTask(uuid, params);
    if (result != null) return result;
    await refreshPendingTasks();
    await refreshAutocompleteData();

    if (_isCalendarSyncEnabled) {
      final updated = await _repo.getTaskByUuid(uuid);
      if (updated != null) {
        try {
          await _calendarService.syncTask(updated);
        } catch (e) {
          return 'Calendar sync failed.';
        }
      }
    }
    return null;
  }

  Future<String?> updateTaskSeries(String uuid, UpdateTaskParams params) async {
    final task = await getTaskByUuid(uuid);
    if (task == null) return 'Task not found';
    final seriesUuid = task.isRecurringTemplate ? task.uuid : task.parentUuid;
    if (seriesUuid == null) return 'Task is not part of a recurring series';
    return await updateTask(seriesUuid, params);
  }

  Future<String?> setRecurrenceLimit(int limit) async {
    final result = await _repo.setRecurrenceLimit(limit);
    if (result != null) return result;
    await refreshPendingTasks();
    return null;
  }

  Future<String?> undo() async {
    final result = await _repo.undo();
    if (result != null) return result;
    await refreshPendingTasks();
    await refreshAutocompleteData();
    return null;
  }

  void toggleTaskSelection(String uuid) {
    _selectionService.toggle(uuid);
    notifyListeners();
  }

  void clearSelection() {
    _selectionService.clear();
    notifyListeners();
  }

  Future<String?> bulkMarkDone() async {
    final ids = _selectionService.selectedUuids
        .where(
          (uuid) => _repo.findTaskByUuid(uuid)?.isRecurringTemplate != true,
        )
        .toList();
    if (ids.isEmpty) return null;

    final result = await _repo.bulkMarkDone(ids);
    if (result != null) return result;

    if (_isCalendarSyncEnabled) {
      final calendarErrors = <String>[];
      for (final id in ids) {
        try {
          await _calendarService.deleteTask(id);
        } catch (e) {
          calendarErrors.add(id);
        }
      }
      if (calendarErrors.isNotEmpty) {
        return 'Calendar sync failed for ${calendarErrors.length} task(s).';
      }
    }
    clearSelection();
    await refreshPendingTasks();
    await refreshAutocompleteData();
    return null;
  }

  Future<String?> bulkDelete() async {
    final ids = _selectionService.selectedUuids
        .where(
          (uuid) => _repo.findTaskByUuid(uuid)?.isRecurringTemplate != true,
        )
        .toList();
    if (ids.isEmpty) return null;

    final result = await _repo.bulkDelete(ids);
    if (result != null) return result;

    if (_isCalendarSyncEnabled) {
      final calendarErrors = <String>[];
      for (final id in ids) {
        try {
          await _calendarService.deleteTask(id);
        } catch (e) {
          calendarErrors.add(id);
        }
      }
      if (calendarErrors.isNotEmpty) {
        return 'Calendar sync failed for ${calendarErrors.length} task(s).';
      }
    }
    clearSelection();
    await refreshPendingTasks();
    await refreshAutocompleteData();
    return null;
  }

  void setSearchQuery(String query) {
    _filterService.setSearchQuery(query);
    _scheduleQueryRefresh();
    _tabService.scheduleSave(_currentProfileId, _filterService);
    notifyListeners();
  }

  void _scheduleQueryRefresh() {
    _debounceFilterTimer?.cancel();
    _debounceFilterTimer = Timer(const Duration(milliseconds: 250), () {
      unawaited(refreshPendingTasks());
    });
  }

  void toggleTag(String tag) {
    _filterService.toggleTag(tag);
    _tabService.scheduleSave(_currentProfileId, _filterService);
    _scheduleQueryRefresh();
    notifyListeners();
  }

  void toggleProject(String project) {
    _filterService.toggleProject(project);
    _tabService.scheduleSave(_currentProfileId, _filterService);
    _scheduleQueryRefresh();
    notifyListeners();
  }

  void toggleExcludedTag(String tag) {
    _filterService.toggleExcludedTag(tag);
    _tabService.scheduleSave(_currentProfileId, _filterService);
    _scheduleQueryRefresh();
    notifyListeners();
  }

  void toggleExcludedProject(String project) {
    _filterService.toggleExcludedProject(project);
    _tabService.scheduleSave(_currentProfileId, _filterService);
    _scheduleQueryRefresh();
    notifyListeners();
  }

  void setTagFilters({
    required Set<String> include,
    required Set<String> exclude,
    required FilterMatchMode mode,
  }) {
    _filterService.setTagFilters(
      include: include,
      exclude: exclude,
      mode: mode,
    );
    _tabService.scheduleSave(_currentProfileId, _filterService);
    _scheduleQueryRefresh();
    notifyListeners();
  }

  void setProjectFilters({
    required Set<String> include,
    required Set<String> exclude,
    required FilterMatchMode mode,
  }) {
    _filterService.setProjectFilters(
      include: include,
      exclude: exclude,
      mode: mode,
    );
    _tabService.scheduleSave(_currentProfileId, _filterService);
    _scheduleQueryRefresh();
    notifyListeners();
  }

  void clearFilters() {
    _filterService.clearFilters();
    _scheduleQueryRefresh();
    _tabService.scheduleSave(_currentProfileId, _filterService);
    notifyListeners();
  }

  Future<void> switchToTab(String tabId) async {
    await _tabService.switchToTab(tabId, _filterService);
    _filterService.invalidateCache();
    _scheduleQueryRefresh();
    notifyListeners();
  }

  Future<void> addFilterTab(String name) async {
    await _tabService.addTab(name, _filterService);
    if (_currentProfileId != null) {
      await _tabService.saveTabs(_currentProfileId!);
    }
    notifyListeners();
  }

  Future<void> deleteFilterTab(String id) async {
    await _tabService.deleteTab(id, _filterService);
    if (_currentProfileId != null) {
      await _tabService.saveTabs(_currentProfileId!);
    }
    _filterService.invalidateCache();
    notifyListeners();
  }

  Future<void> renameFilterTab(String id, String name) async {
    await _tabService.renameTab(id, name);
    if (_currentProfileId != null) {
      await _tabService.saveTabs(_currentProfileId!);
    }
    notifyListeners();
  }

  Future<void> _loadContexts(String profileId) async {
    await _ctxService.loadContexts(profileId);
  }

  void defineContext(String name, String query, {String writeQuery = ''}) {
    _ctxService.defineContext(name, query, writeQuery: writeQuery);
    _filterService.invalidateCache();
    notifyListeners();
    if (_currentProfileId != null) {
      unawaited(_ctxService.saveContexts(_currentProfileId!));
    }
  }

  Future<void> deleteContext(String id) async {
    final wasActive = _ctxService.activeContextId == id;
    _ctxService.deleteContext(id);
    _filterService.invalidateCache();
    notifyListeners();
    if (_currentProfileId != null) {
      await _ctxService.saveContexts(_currentProfileId!);
    }
    if (wasActive) {
      unawaited(refreshPendingTasks());
    }
  }

  void setActiveContext(String? id) {
    _ctxService.setActiveContext(id);
    _filterService.invalidateCache();
    notifyListeners();
    if (_currentProfileId != null) {
      unawaited(_ctxService.saveContexts(_currentProfileId!));
    }
    unawaited(refreshPendingTasks());
  }

  void clearActiveContext() {
    setActiveContext(null);
  }

  Future<void> updateContext(
    String id,
    String name,
    String query, {
    String writeQuery = '',
  }) async {
    _ctxService.updateContext(id, name, query, writeQuery: writeQuery);
    _filterService.invalidateCache();
    notifyListeners();
    if (_currentProfileId != null) {
      await _ctxService.saveContexts(_currentProfileId!);
    }
    if (_ctxService.activeContextId == id) {
      unawaited(refreshPendingTasks());
    }
  }

  String getTaskDescription(String uuid) {
    final task = _repo.findTaskByUuid(uuid);
    if (task != null) {
      return task.description;
    }
    return 'Task (${uuid.substring(0, 8)})';
  }

  Future<int> getTotalTaskCount() async {
    return await _repo.getTotalTaskCount(effectiveSearchQuery);
  }

  void clearProfile() {
    _repo.clearProfile();
    _filterService.clearFilters();
    _tabService.clear();
    _queueService.setQueueView(TaskQueueView.ready);
    _currentProfileId = null;
    _ctxService.clear();
    notifyListeners();
  }

  @override
  void dispose() {
    _tabService.dispose();
    _debounceFilterTimer?.cancel();
    _syncService.dispose();
    _repo.dispose();
    super.dispose();
  }

  Future<String?> sync(Profile profile) async {
    _isSyncing = true;
    notifyListeners();
    try {
      final dbDir = await resolveProfileStorageDir(profile);
      final error = await _syncService.sync(
        dbDir.path,
        profile.serverUrl,
        profile.uuid,
        profile.secret,
        _repo.recurrenceLimit,
      );
      if (error != null) return error;

      await refreshPendingTasks();
      await refreshAutocompleteData();
      return null;
    } catch (e) {
      return e.toString();
    } finally {
      _isSyncing = false;
      notifyListeners();
    }
  }

  Future<String?> exportData({required bool includeDeleted}) async {
    return await _repo.exportData(includeDeleted: includeDeleted);
  }

  Future<String?> importData(String jsonData) async {
    final result = await _repo.importData(jsonData);
    if (result != null) return result;
    await refreshPendingTasks();
    await refreshAutocompleteData();
    return null;
  }
}
