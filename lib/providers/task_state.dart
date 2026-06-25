import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:taskdroid/models/filter_tab.dart';
import 'package:taskdroid/models/profile.dart';
import 'package:taskdroid/models/task_context.dart';
import 'package:taskdroid/services/calendar_service.dart';
import 'package:taskdroid/services/profile_storage.dart';
import 'package:taskdroid/services/sync_isolate_service.dart';
import 'package:taskdroid/services/task_repository.dart';
import 'package:taskdroid/services/task_query_language.dart';
import 'package:taskdroid/src/rust/api.dart';
import 'package:uuid/uuid.dart';

enum TaskQueueView { ready, waiting, scheduled }

class TaskState extends ChangeNotifier {
  final TaskRepository _repo = TaskRepository();
  final CalendarService _calendarService = CalendarService();
  final SyncIsolateService _syncService = SyncIsolateService();

  bool _isSyncing = false;

  String _searchQuery = '';
  Set<String>? _includeTags;
  Set<String>? _excludeTags;
  FilterMatchMode? _tagMatchMode;
  Set<String>? _includeProjects;
  Set<String>? _excludeProjects;
  FilterMatchMode? _projectMatchMode;

  List<FilterTab> _filterTabs = [];
  String? _currentTabId;
  String? _currentProfileId;

  List<TaskContext> _contexts = [];
  String? _activeContextId;
  bool _isCalendarSyncEnabled = false;
  Timer? _saveTabTimer;
  Timer? _debounceFilterTimer;
  TaskQueueView _queueView = TaskQueueView.ready;

  final Set<String> _selectedTaskUuids = {};

  List<TaskView>? _cachedFilteredTasks;
  String? _lastFilterKey;
  String? _lastParsedSearchQuery;
  TaskQuery? _parsedSearchQuery;

  TaskManager? get taskManager => _repo.taskManager;
  List<TaskView> get pendingTasks => _repo.readyTasks;
  List<TaskView> get waitingTasks => _repo.waitingTasks;
  List<TaskView> get scheduledTasks => _repo.scheduledTasks;
  TaskQueueView get queueView => _queueView;
  List<TaskView> get currentViewTasks => _sourceTasksForCurrentView();
  bool get isLoading => _repo.isLoading;
  bool get isSyncing => _isSyncing;
  String? get error => _repo.error;
  String get searchQuery => _searchQuery;
  TaskQuery get parsedSearchQuery => _getParsedSearchQuery();
  Set<String> get selectedTags => includeTags;
  Set<String> get selectedProjects => includeProjects;
  Set<String> get includeTags => _includeTags ?? <String>{};
  Set<String> get excludeTags => _excludeTags ?? <String>{};
  FilterMatchMode get tagMatchMode => _tagMatchMode ?? FilterMatchMode.and;
  Set<String> get includeProjects => _includeProjects ?? <String>{};
  Set<String> get excludeProjects => _excludeProjects ?? <String>{};
  FilterMatchMode get projectMatchMode =>
      _projectMatchMode ?? FilterMatchMode.and;
  List<FilterTab> get filterTabs => _filterTabs;
  String? get currentProfileId => _currentProfileId;
  Set<String> get selectedTaskUuids => _selectedTaskUuids;
  bool get isSelectionMode => _selectedTaskUuids.isNotEmpty;

  /// True when the query explicitly requests non-pending statuses such as
  /// status:completed, +COMPLETED, or status:deleted.
  bool get usesExplicitStatusScope =>
      _getParsedSearchQuery().usesExplicitStatusScope;
  List<TaskView> get displaySourceTasks =>
      usesExplicitStatusScope ? _repo.allTasks : _sourceTasksForCurrentView();

  FilterTab? get currentTab {
    if (_currentTabId == null) return null;
    try {
      return _filterTabs.firstWhere((tab) => tab.id == _currentTabId);
    } catch (_) {
      return null;
    }
  }

  List<TaskContext> get contexts => _contexts;
  TaskContext? get activeContext {
    if (_activeContextId == null) return null;
    try {
      return _contexts.firstWhere((c) => c.id == _activeContextId);
    } catch (_) {
      return null;
    }
  }

  bool get hasActiveContext => activeContext != null;

  String get effectiveSearchQuery {
    final contextQuery = activeContext?.searchQuery ?? '';
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
        await Future.wait(
            [refreshPendingTasks(), _repo.refreshAutocompleteData()]);
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

      await _repo.loadProfile(
        profile.id,
        dbDir.path,
        profile.recurrenceLimit,
      );

      await _loadFilterTabs(profile.id);
      await _loadContexts(profile.id);

      await Future.wait(
          [refreshPendingTasks(), _repo.refreshAutocompleteData()]);
    } catch (e) {
      debugPrint('Failed to load profile: $e');
      notifyListeners();
    }
  }

  Future<void> refreshPendingTasks() async {
    await _repo.refreshPendingTasks(effectiveSearchQuery);
    _cachedFilteredTasks = null;
    notifyListeners();
  }

  List<TaskView> get filteredTasks {
    final parsedQuery = _getParsedSearchQuery();
    final filterKey =
        '${_queueView.name}:${_sortedStrings(includeTags).join(',')}:${_sortedStrings(excludeTags).join(',')}:${tagMatchMode.name}:${_sortedStrings(includeProjects).join(',')}:${_sortedStrings(excludeProjects).join(',')}:${projectMatchMode.name}:${parsedQuery.usesExplicitStatusScope ? 'explicit-status' : 'queue'}';

    if (_cachedFilteredTasks != null && _lastFilterKey == filterKey) {
      return _cachedFilteredTasks!;
    }

    final source = displaySourceTasks;
    final now = DateTime.now().toUtc();
    var filtered = source
        .where((task) => _matchesTaskFilters(task, now))
        .toList();

    _cachedFilteredTasks = filtered;
    _lastFilterKey = filterKey;
    return filtered;
  }

  Future<void> refreshAutocompleteData() async {
    await _repo.refreshAutocompleteData();
    notifyListeners();
  }

  String _buildFilterQuery() {
    final parts = <String>[];
    final incTags = includeTags;
    final excTags = excludeTags;
    final incProjs = includeProjects;
    final excProjs = excludeProjects;

    if (incTags.isNotEmpty) {
      final quoted = incTags.map(_quoteToken);
      if (tagMatchMode == FilterMatchMode.or) {
        parts.add('(${quoted.map((t) => '+$t').join(' or ')})');
      } else {
        parts.addAll(quoted.map((t) => '+$t'));
      }
    }
    for (final tag in excTags) {
      parts.add('-${_quoteToken(tag)}');
    }
    if (incProjs.isNotEmpty) {
      final quoted = incProjs.map(_quoteToken);
      if (projectMatchMode == FilterMatchMode.or) {
        parts.add('(${quoted.map((p) => 'project:$p').join(' or ')})');
      } else {
        parts.addAll(quoted.map((p) => 'project:$p'));
      }
    }
    for (final project in excProjs) {
      parts.add('-project:${_quoteToken(project)}');
    }
    final userQuery = _searchQuery.trim();
    if (userQuery.isNotEmpty) parts.add(userQuery);
    return parts.isEmpty ? '' : parts.join(' ');
  }

  // Quote token values for the Rust query parser.
  // The tokenizer treats both " and ' as interchangeable delimiters.
  // When both quote types appear (extremely rare for tag/project names),
  // we normalize by replacing " with ' so the outer double quotes remain valid.
  String _quoteToken(String raw) {
    if (raw.contains(' ') ||
        raw.contains('\t') ||
        raw.contains(':') ||
        raw.contains('(') ||
        raw.contains(')')) {
      if (raw.contains('"') && raw.contains("'")) {
        return '"${raw.replaceAll('"', "'")}"';
      }
      if (raw.contains('"')) {
        return "'$raw'";
      }
      return '"$raw"';
    }
    return raw;
  }

  @visibleForTesting
  bool matchesTaskFilters(TaskView task) =>
      _matchesTaskFilters(task, DateTime.now().toUtc());

  TaskQuery _getParsedSearchQuery() {
    final query = effectiveSearchQuery;
    if (_parsedSearchQuery != null && _lastParsedSearchQuery == query) {
      return _parsedSearchQuery!;
    }
    final parsed = parseTaskQuery(query);
    _lastParsedSearchQuery = query;
    _parsedSearchQuery = parsed;
    return parsed;
  }

  List<String> _sortedStrings(Iterable<String> values) {
    final sorted = values.toList()..sort();
    return sorted;
  }

  bool _matchesTaskFilters(TaskView task, DateTime nowUtc) {
    final taskTags = task.tags.map((t) => t.toLowerCase()).toSet();
    final incTags = includeTags;
    if (incTags.isNotEmpty) {
      if (tagMatchMode == FilterMatchMode.or) {
        if (!incTags.any((t) => taskTags.contains(t.toLowerCase())))
          return false;
      } else {
        if (!incTags.every((t) => taskTags.contains(t.toLowerCase())))
          return false;
      }
    }
    for (final tag in excludeTags) {
      if (taskTags.contains(tag.toLowerCase())) return false;
    }
    final incProjs = includeProjects;
    if (incProjs.isNotEmpty) {
      final project = task.project;
      if (project == null || project.isEmpty) return false;
      final lowerProject = project.toLowerCase();
      if (projectMatchMode == FilterMatchMode.or) {
        if (!incProjs.any(
          (p) =>
              lowerProject == p.toLowerCase() ||
              lowerProject.startsWith('${p.toLowerCase()}.'),
        ))
          return false;
      } else {
        if (!incProjs.every(
          (p) =>
              lowerProject == p.toLowerCase() ||
              lowerProject.startsWith('${p.toLowerCase()}.'),
        ))
          return false;
      }
    }
    for (final proj in excludeProjects) {
      final project = task.project;
      if (project != null) {
        final lowerProject = project.toLowerCase();
        final lowerProj = proj.toLowerCase();
        if (lowerProject == lowerProj ||
            lowerProject.startsWith('$lowerProj.')) {
          return false;
        }
      }
    }
    return true;
  }

  void setQueueView(TaskQueueView view) {
    if (_queueView == view) return;
    _queueView = view;
    _cachedFilteredTasks = null;
    notifyListeners();
  }

  List<TaskView> _sourceTasksForCurrentView() {
    switch (_queueView) {
      case TaskQueueView.ready:
        return _repo.readyTasks;
      case TaskQueueView.waiting:
        return _repo.waitingTasks;
      case TaskQueueView.scheduled:
        return _repo.scheduledTasks;
    }
  }

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
    if (_selectedTaskUuids.contains(uuid)) {
      _selectedTaskUuids.remove(uuid);
    } else {
      _selectedTaskUuids.add(uuid);
    }
    notifyListeners();
  }

  void clearSelection() {
    _selectedTaskUuids.clear();
    notifyListeners();
  }

  Future<String?> bulkMarkDone() async {
    final ids = _selectedTaskUuids
        .where((uuid) => _repo.findTaskByUuid(uuid)?.isRecurringTemplate != true)
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
    final ids = _selectedTaskUuids
        .where((uuid) => _repo.findTaskByUuid(uuid)?.isRecurringTemplate != true)
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

  Future<void> _loadFilterTabs(String profileId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonString = prefs.getString('filter_tabs_$profileId');

      if (jsonString != null && jsonString.isNotEmpty) {
        final List<dynamic> tabsJson = jsonDecode(jsonString);
        _filterTabs = tabsJson.map((j) => FilterTab.fromJson(j)).toList();
        _currentTabId = prefs.getString('current_tab_id_$profileId');

        final tab = currentTab;
        if (tab != null) {
          _applyTab(tab);
        }
      } else {
        final defaultTab = FilterTab(id: const Uuid().v4(), name: 'All Tasks');
        _filterTabs = [defaultTab];
        _currentTabId = defaultTab.id;
        _applyTab(defaultTab);
        await _saveFilterTabs(profileId);
      }
      _cachedFilteredTasks = null;
    } catch (e) {
      debugPrint('Tab load error: $e');
    }
  }

  Future<void> _saveFilterTabs(String profileId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'filter_tabs_$profileId',
      jsonEncode(_filterTabs.map((t) => t.toJson()).toList()),
    );
    if (_currentTabId != null) {
      await prefs.setString('current_tab_id_$profileId', _currentTabId!);
    }
  }

  void setSearchQuery(String query) {
    _searchQuery = query;
    _lastParsedSearchQuery = null;
    _parsedSearchQuery = null;
    _cachedFilteredTasks = null;
    _scheduleQueryRefresh();
    _scheduleTabUpdate();
    notifyListeners();
  }

  void _scheduleQueryRefresh() {
    _debounceFilterTimer?.cancel();
    _debounceFilterTimer = Timer(const Duration(milliseconds: 250), () {
      unawaited(refreshPendingTasks());
    });
  }

  void toggleTag(String tag) {
    final include = Set<String>.from(_includeTags ?? <String>{});
    if (include.contains(tag)) {
      include.remove(tag);
    } else {
      include.add(tag);
    }
    _includeTags = include;
    _excludeTags ??= <String>{};
    _tagMatchMode ??= FilterMatchMode.and;
    _cachedFilteredTasks = null;
    _scheduleTabUpdate();
    _scheduleQueryRefresh();
    notifyListeners();
  }

  void toggleProject(String project) {
    final include = Set<String>.from(_includeProjects ?? <String>{});
    if (include.contains(project)) {
      include.remove(project);
    } else {
      include.add(project);
    }
    _includeProjects = include;
    _excludeProjects ??= <String>{};
    _projectMatchMode ??= FilterMatchMode.and;
    _cachedFilteredTasks = null;
    _scheduleTabUpdate();
    _scheduleQueryRefresh();
    notifyListeners();
  }

  void toggleExcludedTag(String tag) {
    final exclude = Set<String>.from(_excludeTags ?? <String>{});
    final include = Set<String>.from(_includeTags ?? <String>{});
    if (exclude.contains(tag)) {
      exclude.remove(tag);
    } else {
      exclude.add(tag);
      include.remove(tag);
    }
    _excludeTags = exclude;
    _includeTags = include;
    _tagMatchMode ??= FilterMatchMode.and;
    _cachedFilteredTasks = null;
    _scheduleTabUpdate();
    _scheduleQueryRefresh();
    notifyListeners();
  }

  void toggleExcludedProject(String project) {
    final exclude = Set<String>.from(_excludeProjects ?? <String>{});
    final include = Set<String>.from(_includeProjects ?? <String>{});
    if (exclude.contains(project)) {
      exclude.remove(project);
    } else {
      exclude.add(project);
      include.remove(project);
    }
    _excludeProjects = exclude;
    _includeProjects = include;
    _projectMatchMode ??= FilterMatchMode.and;
    _cachedFilteredTasks = null;
    _scheduleTabUpdate();
    _scheduleQueryRefresh();
    notifyListeners();
  }

  void setTagFilters({
    required Set<String> include,
    required Set<String> exclude,
    required FilterMatchMode mode,
  }) {
    _includeTags = include;
    _excludeTags = exclude;
    _tagMatchMode = mode;
    _cachedFilteredTasks = null;
    _scheduleTabUpdate();
    _scheduleQueryRefresh();
    notifyListeners();
  }

  void setProjectFilters({
    required Set<String> include,
    required Set<String> exclude,
    required FilterMatchMode mode,
  }) {
    _includeProjects = include;
    _excludeProjects = exclude;
    _projectMatchMode = mode;
    _cachedFilteredTasks = null;
    _scheduleTabUpdate();
    _scheduleQueryRefresh();
    notifyListeners();
  }

  void clearFilters() {
    _searchQuery = '';
    _lastParsedSearchQuery = null;
    _parsedSearchQuery = null;
    _includeTags = <String>{};
    _excludeTags = <String>{};
    _tagMatchMode = FilterMatchMode.and;
    _includeProjects = <String>{};
    _excludeProjects = <String>{};
    _projectMatchMode = FilterMatchMode.and;
    _cachedFilteredTasks = null;
    _scheduleQueryRefresh();
    _scheduleTabUpdate();
    notifyListeners();
  }

  Future<void> switchToTab(String tabId) async {
    _saveTabTimer?.cancel();
    await _persistCurrentTabSettings();

    _currentTabId = tabId;
    final tab = currentTab;
    if (tab != null) {
      _applyTab(tab);
    }
    _cachedFilteredTasks = null;
    _scheduleQueryRefresh();
    notifyListeners();
  }

  Future<void> addFilterTab(String name) async {
    final newTab = FilterTab(
      id: const Uuid().v4(),
      name: name,
      searchQuery: _searchQuery,
      selectedTags: const <String>{},
      selectedProjects: const <String>{},
      includeTags: _includeTags == null ? null : Set.from(_includeTags!),
      excludeTags: _excludeTags == null ? null : Set.from(_excludeTags!),
      tagMatchMode: _tagMatchMode,
      includeProjects: _includeProjects == null
          ? null
          : Set.from(_includeProjects!),
      excludeProjects: _excludeProjects == null
          ? null
          : Set.from(_excludeProjects!),
      projectMatchMode: _projectMatchMode,
    );

    _filterTabs = [
      ..._filterTabs,
      newTab,
    ]; // immutable update fixes the assertion crash
    _currentTabId = newTab.id;
    if (_currentProfileId != null) await _saveFilterTabs(_currentProfileId!);
    notifyListeners();
  }

  Future<void> deleteFilterTab(String id) async {
    if (_filterTabs.length <= 1) return;

    _filterTabs = _filterTabs
        .where((t) => t.id != id)
        .toList(); // immutable update
    if (_currentTabId == id) await switchToTab(_filterTabs.first.id);
    if (_currentProfileId != null) await _saveFilterTabs(_currentProfileId!);
    notifyListeners();
  }

  Future<void> renameFilterTab(String id, String name) async {
    final idx = _filterTabs.indexWhere((t) => t.id == id);
    if (idx != -1) {
      final newList = List<FilterTab>.from(_filterTabs);
      newList[idx] = newList[idx].copyWith(name: name);
      _filterTabs = newList; // immutable update
      if (_currentProfileId != null) await _saveFilterTabs(_currentProfileId!);
      notifyListeners();
    }
  }

  void _scheduleTabUpdate() {
    _saveTabTimer?.cancel();
    _saveTabTimer = Timer(
      const Duration(milliseconds: 500),
      () => _persistCurrentTabSettings(),
    );
  }

  Future<void> _persistCurrentTabSettings() async {
    if (_currentProfileId == null || _currentTabId == null) return;
    final idx = _filterTabs.indexWhere((t) => t.id == _currentTabId);
    if (idx != -1) {
      final newList = List<FilterTab>.from(_filterTabs);
      final current = newList[idx];
      newList[idx] = FilterTab(
        id: current.id,
        name: current.name,
        searchQuery: _searchQuery,
        selectedTags: const <String>{},
        selectedProjects: const <String>{},
        includeTags: _includeTags,
        excludeTags: _excludeTags,
        tagMatchMode: _tagMatchMode,
        includeProjects: _includeProjects,
        excludeProjects: _excludeProjects,
        projectMatchMode: _projectMatchMode,
      );
      _filterTabs = newList; // immutable update
      await _saveFilterTabs(_currentProfileId!);
    }
  }

  void _applyTab(FilterTab tab) {
    _searchQuery = _migratedSearchQuery(tab);
    _lastParsedSearchQuery = null;
    _parsedSearchQuery = null;
    _includeTags = tab.includeTags == null
        ? Set.from(tab.selectedTags)
        : Set.from(tab.includeTags!);
    _excludeTags = tab.excludeTags == null ? null : Set.from(tab.excludeTags!);
    _tagMatchMode = tab.tagMatchMode ?? FilterMatchMode.and;
    _includeProjects = tab.includeProjects == null
        ? Set.from(tab.selectedProjects)
        : Set.from(tab.includeProjects!);
    _excludeProjects = tab.excludeProjects == null
        ? null
        : Set.from(tab.excludeProjects!);
    _projectMatchMode = tab.projectMatchMode ?? FilterMatchMode.and;
  }

  Future<void> _loadContexts(String profileId) async {
    _contexts = [];
    _activeContextId = null;
    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonString = prefs.getString('contexts_$profileId');
      if (jsonString != null && jsonString.isNotEmpty) {
        final List<dynamic> contextsJson = jsonDecode(jsonString);
        _contexts = contextsJson.map((j) => TaskContext.fromJson(j)).toList();
        final activeId = prefs.getString('active_context_id_$profileId');
        _activeContextId = activeId;
      }
    } catch (e) {
      debugPrint('Context load error: $e');
    }
  }

  Future<void> _saveContexts(String profileId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'contexts_$profileId',
      jsonEncode(_contexts.map((c) => c.toJson()).toList()),
    );
    if (_activeContextId != null) {
      await prefs.setString('active_context_id_$profileId', _activeContextId!);
    } else {
      await prefs.remove('active_context_id_$profileId');
    }
  }

  void defineContext(String name, String query, {String writeQuery = ''}) {
    final context = TaskContext(
      id: const Uuid().v4(),
      name: name,
      searchQuery: query,
      writeQuery: writeQuery,
    );
    _contexts = [..._contexts, context];
    _cachedFilteredTasks = null;
    notifyListeners();
    if (_currentProfileId != null) {
      unawaited(_saveContexts(_currentProfileId!));
    }
  }

  Future<void> deleteContext(String id) async {
    final wasActive = _activeContextId == id;
    _contexts = _contexts.where((c) => c.id != id).toList();
    if (wasActive) {
      _activeContextId = null;
      _lastParsedSearchQuery = null;
      _parsedSearchQuery = null;
    }
    _cachedFilteredTasks = null;
    notifyListeners();
    if (_currentProfileId != null) {
      await _saveContexts(_currentProfileId!);
    }
    if (wasActive) {
      unawaited(refreshPendingTasks());
    }
  }

  void setActiveContext(String? id) {
    if (id != null && !_contexts.any((c) => c.id == id)) return;
    _activeContextId = id;
    _lastParsedSearchQuery = null;
    _parsedSearchQuery = null;
    _cachedFilteredTasks = null;
    notifyListeners();
    if (_currentProfileId != null) {
      unawaited(_saveContexts(_currentProfileId!));
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
    final idx = _contexts.indexWhere((c) => c.id == id);
    if (idx != -1) {
      final newList = List<TaskContext>.from(_contexts);
      newList[idx] = newList[idx].copyWith(
        name: name,
        searchQuery: query,
        writeQuery: writeQuery,
      );
      _contexts = newList;
      _lastParsedSearchQuery = null;
      _parsedSearchQuery = null;
      _cachedFilteredTasks = null;
      notifyListeners();
      if (_currentProfileId != null) {
        await _saveContexts(_currentProfileId!);
      }
      if (_activeContextId == id) {
        unawaited(refreshPendingTasks());
      }
    }
  }

  String _migratedSearchQuery(FilterTab tab) {
    final fragments = <String>[];
    final search = tab.searchQuery.trim();
    if (search.isNotEmpty) fragments.add(search);

    final includeStatuses = _decodeStatuses(tab.includeStatuses) ?? {};
    final includeStatusFragments = includeStatuses
        .map((status) => 'status:${status.name}')
        .toList();
    if (includeStatusFragments.length > 1) {
      fragments.add('(${includeStatusFragments.join(' or ')})');
    } else {
      fragments.addAll(includeStatusFragments);
    }

    final excludeStatuses = _decodeStatuses(tab.excludeStatuses) ?? {};
    fragments.addAll(excludeStatuses.map((status) => '-status:${status.name}'));

    final includeFlags = _decodeFlags(tab.includeFlags) ?? {};
    final includeFlagFragments = includeFlags
        .map((flag) => '+${_flagQueryToken(flag)}')
        .toList();
    if (includeFlagFragments.length > 1 &&
        tab.flagMatchMode == FilterMatchMode.or) {
      fragments.add('(${includeFlagFragments.join(' or ')})');
    } else {
      fragments.addAll(includeFlagFragments);
    }

    final excludeFlags = _decodeFlags(tab.excludeFlags) ?? {};
    fragments.addAll(excludeFlags.map((flag) => '-${_flagQueryToken(flag)}'));

    return fragments.join(' ');
  }

  String _flagQueryToken(TaskVirtualFlag flag) => flag.name.toLowerCase();

  Set<TaskStatus>? _decodeStatuses(Set<String>? raw) {
    if (raw == null) return null;
    final parsed = <TaskStatus>{};
    for (final value in raw) {
      for (final status in TaskStatus.values) {
        if (status.name == value) {
          parsed.add(status);
          break;
        }
      }
    }
    return parsed;
  }

  Set<TaskVirtualFlag>? _decodeFlags(Set<String>? raw) {
    if (raw == null) return null;
    final parsed = <TaskVirtualFlag>{};
    for (final value in raw) {
      for (final flag in TaskVirtualFlag.values) {
        if (flag.name == value) {
          parsed.add(flag);
          break;
        }
      }
    }
    return parsed;
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
    _queueView = TaskQueueView.ready;
    _currentProfileId = null;
    _currentTabId = null;
    _lastParsedSearchQuery = null;
    _parsedSearchQuery = null;
    _contexts = [];
    _activeContextId = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _saveTabTimer?.cancel();
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
