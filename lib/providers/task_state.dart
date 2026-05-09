import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:taskdroid/models/filter_tab.dart';
import 'package:taskdroid/models/profile.dart';
import 'package:taskdroid/models/task_virtual_flags.dart';
import 'package:taskdroid/services/calendar_service.dart';
import 'package:taskdroid/services/task_filter_evaluator.dart';
import 'package:taskdroid/services/task_query_language.dart';
import 'package:taskdroid/src/rust/api.dart';
import 'package:taskdroid/src/rust/frb_generated.dart';
import 'package:uuid/uuid.dart';

enum TaskQueueView { ready, waiting, scheduled }

class TaskState extends ChangeNotifier {
  static const String _recurrenceLimitUdaKey = 'taskdroid.recurrence.limit';

  TaskManager? _taskManager;
  List<TaskView> _allTasks = [];
  List<TaskView> _readyTasks = [];
  List<TaskView> _waitingTasks = [];
  List<TaskView> _scheduledTasks = [];
  final Map<String, TaskView> _taskByUuid = {};
  bool _isLoading = false;
  bool _isSyncing = false;
  String? _error;

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
  bool _isCalendarSyncEnabled = false;
  int _recurrenceLimit = 1;
  Timer? _saveTabTimer;
  Timer? _debounceFilterTimer;
  TaskQueueView _queueView = TaskQueueView.ready;
  bool _needsRefreshAfterCurrentLoad = false;

  final Set<String> _selectedTaskUuids = {};

  List<TaskView>? _cachedFilteredTasks;
  String? _lastFilterKey;
  String? _lastParsedSearchQuery;
  TaskQuery? _parsedSearchQuery;

  TaskManager? get taskManager => _taskManager;
  List<TaskView> get pendingTasks => _readyTasks;
  List<TaskView> get waitingTasks => _waitingTasks;
  List<TaskView> get scheduledTasks => _scheduledTasks;
  TaskQueueView get queueView => _queueView;
  List<TaskView> get currentViewTasks => _sourceTasksForCurrentView();
  bool get isLoading => _isLoading;
  bool get isSyncing => _isSyncing;
  String? get error => _error;
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
      usesExplicitStatusScope ? _allTasks : _sourceTasksForCurrentView();

  final CalendarService _calendarService = CalendarService();

  FilterTab? get currentTab {
    if (_currentTabId == null) return null;
    try {
      return _filterTabs.firstWhere((tab) => tab.id == _currentTabId);
    } catch (_) {
      return null;
    }
  }

  Set<String> get allTags {
    final tags = <String>{};
    for (final task in _allTasks) {
      tags.addAll(task.tags);
    }
    return tags;
  }

  Set<String> get allProjects {
    final projects = <String>{};
    for (final task in _allTasks) {
      if (task.project != null && task.project!.isNotEmpty) {
        projects.add(task.project!);
      }
    }
    return projects;
  }

  Future<void> loadProfile(Profile profile) async {
    if (_taskManager != null && _currentProfileId == profile.id) {
      if (_readyTasks.isEmpty && !_isLoading) {
        await refreshPendingTasks();
      }
      return;
    }

    if (_isLoading && _currentProfileId == profile.id) {
      return;
    }

    _isLoading = true;
    _error = null;
    _currentProfileId = profile.id;
    _isCalendarSyncEnabled = profile.calendarSync;
    _recurrenceLimit = profile.recurrenceLimit < 1
        ? 1
        : profile.recurrenceLimit;
    notifyListeners();

    try {
      final docsDir = await getApplicationDocumentsDirectory();
      final dbDirPath = '${docsDir.path}/${profile.id}/';

      _taskManager = TaskManager();
      await _taskManager!.loadProfile(directoryPath: dbDirPath);

      await _loadFilterTabs(profile.id);

      // Fix: Reset loading guard BEFORE refreshing tasks, else it instantly aborts
      _isLoading = false;
      await refreshPendingTasks();
    } catch (e) {
      debugPrint('Failed to load profile: $e');
      _error = 'Unable to load profile database.';
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> refreshPendingTasks() async {
    if (_taskManager == null) return;
    if (_isLoading) {
      _needsRefreshAfterCurrentLoad = true;
      return;
    }

    _isLoading = true;
    notifyListeners();

    try {
      final filter = TaskFilter(
        status: null,
        project: null,
        tags: [],
        searchTerm: _searchQuery.trim().isEmpty ? null : _searchQuery.trim(),
        offset: BigInt.from(0),
        limit: BigInt.from(5000),
      );

      final result = await _taskManager!.listTasks(filter: filter);
      final now = DateTime.now().toUtc();
      final ready = <TaskView>[];
      final waiting = <TaskView>[];
      final scheduled = <TaskView>[];
      _allTasks = result.tasks;
      _taskByUuid.clear();

      for (final task in result.tasks) {
        _taskByUuid[task.uuid] = task;
        if (task.status == TaskStatus.pending) {
          if (_isWaitingTask(task, now)) {
            waiting.add(task);
          } else if (_isScheduledForFuture(task, now)) {
            scheduled.add(task);
          } else {
            ready.add(task);
          }
        }
      }

      ready.sort((a, b) => b.urgency.compareTo(a.urgency));
      waiting.sort((a, b) => b.urgency.compareTo(a.urgency));
      scheduled.sort((a, b) => b.urgency.compareTo(a.urgency));

      _readyTasks = ready;
      _waitingTasks = waiting;
      _scheduledTasks = scheduled;
      _cachedFilteredTasks = null;
      _error = null;
    } catch (e) {
      _error = 'Failed to sync with local database.';
    } finally {
      _isLoading = false;
      notifyListeners();
      if (_needsRefreshAfterCurrentLoad) {
        _needsRefreshAfterCurrentLoad = false;
        unawaited(refreshPendingTasks());
      }
    }
  }

  bool _isWaitingTask(TaskView task, DateTime nowUtc) {
    return task.isWaitingAt(nowUtc);
  }

  bool _isScheduledForFuture(TaskView task, DateTime nowUtc) {
    return task.isScheduledForFuture(nowUtc);
  }

  List<TaskView> get filteredTasks {
    final parsedQuery = _getParsedSearchQuery();
    final filterKey =
        '${_queueView.name}:$_searchQuery:${_sortedStrings(includeTags).join(',')}:${_sortedStrings(excludeTags).join(',')}:${tagMatchMode.name}:${_sortedStrings(includeProjects).join(',')}:${_sortedStrings(excludeProjects).join(',')}:${projectMatchMode.name}:${parsedQuery.usesExplicitStatusScope ? 'explicit-status' : 'queue'}';

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

  TaskQuery _getParsedSearchQuery() {
    final query = _searchQuery;
    if (_parsedSearchQuery != null && _lastParsedSearchQuery == query) {
      return _parsedSearchQuery!;
    }
    final parsed = parseTaskQuery(query, DateTime.now().toUtc());
    _lastParsedSearchQuery = query;
    _parsedSearchQuery = parsed;
    return parsed;
  }

  List<String> _sortedStrings(Iterable<String> values) {
    final sorted = values.toList()..sort();
    return sorted;
  }

  bool _matchesTaskFilters(TaskView task, DateTime nowUtc) {
    return matchesTaskFilter(
      task,
      TaskFilterCriteria(
        includeTags: includeTags,
        excludeTags: excludeTags,
        tagMatchMode: tagMatchMode,
        includeProjects: includeProjects,
        excludeProjects: excludeProjects,
        projectMatchMode: projectMatchMode,
        includeStatuses: const <TaskStatus>{},
        excludeStatuses: const <TaskStatus>{},
        includeFlags: const <TaskVirtualFlag>{},
        excludeFlags: const <TaskVirtualFlag>{},
        flagMatchMode: FilterMatchMode.and,
      ),
      nowUtc,
    );
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
        return _readyTasks;
      case TaskQueueView.waiting:
        return _waitingTasks;
      case TaskQueueView.scheduled:
        return _scheduledTasks;
    }
  }

  TaskView? findTaskByUuid(String uuid) => _taskByUuid[uuid];

  List<TaskView> get dependencyCandidates => [
    ..._readyTasks,
    ..._waitingTasks,
    ..._scheduledTasks,
  ];

  Future<String?> createTask(CreateTaskParams params) async {
    if (_taskManager == null) return 'No profile loaded';
    try {
      final mergedUdas = _mergeRecurrenceLimitUda(
        params.udas,
        params.recurrence,
      );
      final uuid = await _taskManager!.addTask(
        params: CreateTaskParams(
          description: params.description,
          status: params.status,
          project: params.project,
          priority: params.priority,
          tags: params.tags,
          due: params.due,
          wait: params.wait,
          scheduled: params.scheduled,
          recurrence: params.recurrence,
          until: params.until,
          udas: mergedUdas,
        ),
      );
      await refreshPendingTasks();

      if (_isCalendarSyncEnabled) {
        final newTask = await _taskManager!.getTask(uuidStr: uuid);
        await _calendarService.syncTask(newTask);
      }
      return null;
    } catch (e) {
      return e.toString();
    }
  }

  Future<String?> markTaskDone(String uuid) async {
    if (_taskManager == null) return 'No profile loaded';
    try {
      await _taskManager!.doneTasks(uuidStrs: [uuid]);
      if (_isCalendarSyncEnabled) await _calendarService.deleteTask(uuid);
      await refreshPendingTasks();
      return null;
    } catch (e) {
      return e.toString();
    }
  }

  Future<String?> deleteTask(String uuid) async {
    if (_taskManager == null) return 'No profile loaded';
    try {
      await _taskManager!.deleteTasks(uuidStrs: [uuid]);
      if (_isCalendarSyncEnabled) await _calendarService.deleteTask(uuid);
      await refreshPendingTasks();
      return null;
    } catch (e) {
      return e.toString();
    }
  }

  Future<String?> deleteTaskSingle(String uuid) async {
    if (_taskManager == null) return 'No profile loaded';
    try {
      await _taskManager!.deleteTaskSingle(uuidStr: uuid);
      if (_isCalendarSyncEnabled) await _calendarService.deleteTask(uuid);
      await refreshPendingTasks();
      return null;
    } catch (e) {
      return e.toString();
    }
  }

  Future<String?> deleteTaskSeries(String uuid) async {
    if (_taskManager == null) return 'No profile loaded';
    try {
      await _taskManager!.deleteTaskSeries(uuidStr: uuid);
      if (_isCalendarSyncEnabled) await _calendarService.deleteTask(uuid);
      await refreshPendingTasks();
      return null;
    } catch (e) {
      return e.toString();
    }
  }

  Future<String?> markTaskDoneSingle(String uuid) async {
    if (_taskManager == null) return 'No profile loaded';
    try {
      await _taskManager!.doneTaskSingle(uuidStr: uuid);
      if (_isCalendarSyncEnabled) await _calendarService.deleteTask(uuid);
      await refreshPendingTasks();
      return null;
    } catch (e) {
      return e.toString();
    }
  }

  Future<String?> markTaskDoneSeries(String uuid) async {
    if (_taskManager == null) return 'No profile loaded';
    try {
      await _taskManager!.doneTaskSeries(uuidStr: uuid);
      if (_isCalendarSyncEnabled) await _calendarService.deleteTask(uuid);
      await refreshPendingTasks();
      return null;
    } catch (e) {
      return e.toString();
    }
  }

  Future<String?> updateTask(String uuid, UpdateTaskParams params) async {
    if (_taskManager == null) return 'No profile loaded';
    try {
      final mergedUdas = _mergeRecurrenceLimitUda(
        params.setUdas,
        params.recurrence,
      );
      await _taskManager!.updateTask(
        uuidStr: uuid,
        params: UpdateTaskParams(
          description: params.description,
          status: params.status,
          project: params.project,
          priority: params.priority,
          due: params.due,
          wait: params.wait,
          scheduled: params.scheduled,
          recurrence: params.recurrence,
          until: params.until,
          addTags: params.addTags,
          removeTags: params.removeTags,
          addAnnotation: params.addAnnotation,
          removeAnnotations: params.removeAnnotations,
          addDepends: params.addDepends,
          removeDepends: params.removeDepends,
          start: params.start,
          setUdas: mergedUdas,
        ),
      );
      await refreshPendingTasks();

      if (_isCalendarSyncEnabled) {
        final updated = await _taskManager!.getTask(uuidStr: uuid);
        await _calendarService.syncTask(updated);
      }
      return null;
    } catch (e) {
      return e.toString();
    }
  }

  Future<String?> undo() async {
    if (_taskManager == null) return 'No profile loaded';
    try {
      final success = await _taskManager!.undo();
      if (success) {
        await refreshPendingTasks();
        return null;
      }
      return 'Nothing to undo';
    } catch (e) {
      return 'Undo failed';
    }
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
    if (_taskManager == null) return null;
    final ids = _selectedTaskUuids.toList();
    if (ids.isEmpty) return null;

    try {
      await _taskManager!.doneTasks(uuidStrs: ids);
      if (_isCalendarSyncEnabled) {
        for (var id in ids) {
          _calendarService.deleteTask(id);
        }
      }
      clearSelection();
      await refreshPendingTasks();
      return null;
    } catch (e) {
      return 'Bulk operation failed';
    }
  }

  Future<String?> bulkDelete() async {
    if (_taskManager == null) return null;
    final ids = _selectedTaskUuids.toList();
    if (ids.isEmpty) return null;

    try {
      await _taskManager!.deleteTasks(uuidStrs: ids);
      if (_isCalendarSyncEnabled) {
        for (var id in ids) {
          _calendarService.deleteTask(id);
        }
      }
      clearSelection();
      await refreshPendingTasks();
      return null;
    } catch (e) {
      return 'Bulk delete failed';
    }
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
    final task = _taskByUuid[uuid];
    if (task != null) {
      return task.description;
    }
    return 'Task (${uuid.substring(0, 8)})';
  }

  Future<int> getTotalTaskCount() async {
    if (_taskManager == null) return 0;
    try {
      final result = await _taskManager!.listTasks(
        filter: TaskFilter(
          status: null,
          tags: [],
          searchTerm: null,
          project: null,
          offset: BigInt.from(0),
          limit: BigInt.from(1),
        ),
      );
      return result.totalCount.toInt();
    } catch (_) {
      return _readyTasks.length + _waitingTasks.length;
    }
  }

  void clearProfile() {
    _taskManager = null;
    _readyTasks = [];
    _waitingTasks = [];
    _scheduledTasks = [];
    _allTasks = [];
    _taskByUuid.clear();
    _queueView = TaskQueueView.ready;
    _currentProfileId = null;
    _recurrenceLimit = 1;
    _currentTabId = null;
    _lastParsedSearchQuery = null;
    _parsedSearchQuery = null;
    notifyListeners();
  }

  List<UdaPair> _mergeRecurrenceLimitUda(
    List<UdaPair> source,
    String? recurrence,
  ) {
    final hasRecurrence = recurrence != null && recurrence.trim().isNotEmpty;
    final filtered = source
        .where((pair) => pair.key != _recurrenceLimitUdaKey)
        .toList(growable: true);
    if (hasRecurrence) {
      filtered.add(
        UdaPair(
          key: _recurrenceLimitUdaKey,
          value: _recurrenceLimit.toString(),
        ),
      );
    }
    return filtered;
  }

  @override
  void dispose() {
    _saveTabTimer?.cancel();
    _debounceFilterTimer?.cancel();
    super.dispose();
  }

  Future<String?> sync(Profile profile) async {
    _isSyncing = true;
    notifyListeners();
    try {
      final docsDir = await getApplicationDocumentsDirectory();
      final dbDirPath = '${docsDir.path}/${profile.id}/';

      final result = await compute(
        _syncInIsolate,
        _SyncParams(
          directoryPath: dbDirPath,
          url: profile.serverUrl,
          clientId: profile.uuid,
          encryptionSecret: profile.secret,
        ),
      );

      if (!result.success) return result.error;

      await refreshPendingTasks();
      return null;
    } catch (e) {
      return e.toString();
    } finally {
      _isSyncing = false;
      notifyListeners();
    }
  }

  Future<String?> exportData({required bool includeDeleted}) async {
    if (_taskManager == null) return null;
    return await _taskManager!.exportTasks(includeDeleted: includeDeleted);
  }

  Future<String?> importData(String jsonData) async {
    if (_taskManager == null) return "Profile not loaded";
    try {
      await _taskManager!.importTasks(jsonData: jsonData);
      await refreshPendingTasks();
      return null;
    } catch (e) {
      return e.toString();
    }
  }
}

class _SyncParams {
  final String directoryPath;
  final String url;
  final String clientId;
  final String encryptionSecret;
  _SyncParams({
    required this.directoryPath,
    required this.url,
    required this.clientId,
    required this.encryptionSecret,
  });
}

class _SyncResult {
  final bool success;
  final String? error;
  _SyncResult({required this.success, this.error});
}

Future<_SyncResult> _syncInIsolate(_SyncParams params) async {
  try {
    await RustLib.init();
    final manager = TaskManager();
    await manager.loadProfile(directoryPath: params.directoryPath);
    await manager.sync_(
      url: params.url,
      clientId: params.clientId,
      encryptionSecret: params.encryptionSecret,
    );
    return _SyncResult(success: true);
  } catch (e) {
    return _SyncResult(success: false, error: e.toString());
  }
}
