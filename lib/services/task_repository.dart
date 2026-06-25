import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:taskdroid/models/task_virtual_flags.dart';
import 'package:taskdroid/src/rust/api.dart';

class TaskRepository {
  TaskManager? _taskManager;
  List<TaskView> _allTasks = [];
  List<TaskView> _allAutocompleteTasks = [];
  List<TaskView> _readyTasks = [];
  List<TaskView> _waitingTasks = [];
  List<TaskView> _scheduledTasks = [];
  final Map<String, TaskView> _taskByUuid = {};

  bool _isLoading = false;
  String? _error;
  bool _needsRefreshAfterCurrentLoad = false;

  String? _currentProfileId;
  int _recurrenceLimit = 1;

  // --- getters
  TaskManager? get taskManager => _taskManager;
  List<TaskView> get readyTasks => _readyTasks;
  List<TaskView> get waitingTasks => _waitingTasks;
  List<TaskView> get scheduledTasks => _scheduledTasks;
  bool get isLoading => _isLoading;
  String? get error => _error;
  String? get currentProfileId => _currentProfileId;
  int get recurrenceLimit => _recurrenceLimit;

  List<TaskView> get allTasks => _allTasks;
  TaskView? findTaskByUuid(String uuid) => _taskByUuid[uuid];
  List<TaskView> get dependencyCandidates => [
    ..._readyTasks,
    ..._waitingTasks,
    ..._scheduledTasks,
  ];
  Set<String> get allTags {
    final tags = <String>{};
    for (final task
        in (_allAutocompleteTasks.isNotEmpty
            ? _allAutocompleteTasks
            : _allTasks)) {
      tags.addAll(task.tags);
    }
    return tags;
  }

  Set<String> get allProjects {
    final projects = <String>{};
    for (final task
        in (_allAutocompleteTasks.isNotEmpty
            ? _allAutocompleteTasks
            : _allTasks)) {
      if (task.project != null && task.project!.isNotEmpty) {
        projects.add(task.project!);
      }
    }
    return projects;
  }

  // --- profile init
  Future<void> loadProfile(
    String profileId,
    String dbDir,
    int recurrenceLimit,
  ) async {
    if (_taskManager != null && _currentProfileId == profileId) return;

    _isLoading = true;
    _error = null;
    _currentProfileId = profileId;
    _recurrenceLimit = recurrenceLimit < 0 ? 0 : recurrenceLimit;

    try {
      _taskManager = TaskManager();
      await _taskManager!.loadProfile(directoryPath: dbDir);
      await _taskManager!.setRecurrenceLimit(
        limit: BigInt.from(_recurrenceLimit),
      );
    } catch (e) {
      _error = 'Unable to load profile database.';
      debugPrint('loadProfile error: $e');
    } finally {
      _isLoading = false;
    }
  }

  void clearProfile() {
    _taskManager = null;
    _readyTasks = [];
    _waitingTasks = [];
    _scheduledTasks = [];
    _allTasks = [];
    _allAutocompleteTasks = [];
    _taskByUuid.clear();
    _currentProfileId = null;
    _recurrenceLimit = 1;
    _error = null;
  }

  // --- task fetch/refresh
  Future<void> refreshPendingTasks(String effectiveSearchQuery) async {
    if (_taskManager == null) return;

    if (_isLoading) {
      _needsRefreshAfterCurrentLoad = true;
      return;
    }

    _isLoading = true;
    _error = null;

    try {
      final filter = TaskFilter(
        status: null,
        project: null,
        tags: [],
        searchTerm: effectiveSearchQuery.isEmpty ? null : effectiveSearchQuery,
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
          if (task.isWaitingAt(now)) {
            waiting.add(task);
          } else if (task.isScheduledForFuture(now)) {
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
      _error = null;
    } catch (e) {
      _error = 'Failed to sync with local database.';
      debugPrint('refreshPendingTasks error: $e');
    } finally {
      _isLoading = false;
      if (_needsRefreshAfterCurrentLoad) {
        _needsRefreshAfterCurrentLoad = false;
        unawaited(refreshPendingTasks(effectiveSearchQuery));
      }
    }
  }

  Future<void> refreshAutocompleteData() async {
    if (_taskManager == null) return;

    try {
      final filter = TaskFilter(
        status: null,
        project: null,
        tags: [],
        searchTerm: null,
        offset: BigInt.from(0),
        limit: BigInt.from(5000),
      );
      final result = await _taskManager!.listTasks(filter: filter);
      _allAutocompleteTasks = result.tasks;
    } catch (e) {
      debugPrint('Failed to refresh autocomplete data: $e');
    }
  }

  Future<TaskView?> getTaskByUuid(String uuid) async {
    final cached = _taskByUuid[uuid];
    if (cached != null) return cached;
    if (_taskManager == null) return null;
    try {
      final task = await _taskManager!.getTask(uuidStr: uuid);
      _taskByUuid[task.uuid] = task;
      return task;
    } catch (e) {
      debugPrint('getTaskByUuid: failed to fetch task $uuid: $e');
      return null;
    }
  }

  Future<int> getTotalTaskCount(String effectiveSearchQuery) async {
    if (_taskManager == null) return 0;

    try {
      final filter = TaskFilter(
        status: null,
        project: null,
        tags: [],
        searchTerm: effectiveSearchQuery.isEmpty ? null : effectiveSearchQuery,
        offset: BigInt.from(0),
        limit: BigInt.from(1),
      );
      final result = await _taskManager!.listTasks(filter: filter);
      return result.totalCount.toInt();
    } catch (_) {
      return _readyTasks.length + _waitingTasks.length;
    }
  }

  // --- mutations
  Future<({String? error, String? uuid})> createTask(
    CreateTaskParams params,
  ) async {
    if (_taskManager == null) return (error: 'No profile loaded', uuid: null);
    try {
      final uuid = await _taskManager!.addTask(params: params);
      return (error: null, uuid: uuid);
    } catch (e) {
      return (error: e.toString(), uuid: null);
    }
  }

  Future<String?> markTaskDone(String uuid) async {
    if (_taskManager == null) return 'No profile loaded';
    try {
      await _taskManager!.doneTasks(uuidStrs: [uuid]);
      return null;
    } catch (e) {
      return e.toString();
    }
  }

  Future<String?> deleteTask(String uuid) async {
    if (_taskManager == null) return 'No profile loaded';
    try {
      await _taskManager!.deleteTasks(uuidStrs: [uuid]);
      return null;
    } catch (e) {
      return e.toString();
    }
  }

  Future<String?> deleteTaskSingle(String uuid) async {
    if (_taskManager == null) return 'No profile loaded';
    try {
      await _taskManager!.deleteTaskSingle(uuidStr: uuid);
      return null;
    } catch (e) {
      return e.toString();
    }
  }

  Future<String?> deleteTaskSeries(String uuid) async {
    if (_taskManager == null) return 'No profile loaded';
    try {
      await _taskManager!.deleteTaskSeries(uuidStr: uuid);
      return null;
    } catch (e) {
      return e.toString();
    }
  }

  Future<String?> markTaskDoneSingle(String uuid) async {
    if (_taskManager == null) return 'No profile loaded';
    try {
      await _taskManager!.doneTaskSingle(uuidStr: uuid);
      return null;
    } catch (e) {
      return e.toString();
    }
  }

  Future<String?> updateTask(String uuid, UpdateTaskParams params) async {
    if (_taskManager == null) return 'No profile loaded';
    try {
      await _taskManager!.updateTask(uuidStr: uuid, params: params);
      return null;
    } catch (e) {
      return e.toString();
    }
  }

  Future<String?> undo() async {
    if (_taskManager == null) return 'No profile loaded';
    try {
      final success = await _taskManager!.undo();
      if (success) return null;
      return 'Nothing to undo';
    } catch (e) {
      return 'Undo failed';
    }
  }

  Future<String?> bulkMarkDone(List<String> uuids) async {
    if (_taskManager == null) return null;
    if (uuids.isEmpty) return null;
    try {
      await _taskManager!.doneTasks(uuidStrs: uuids);
      return null;
    } catch (e) {
      return 'Bulk operation failed';
    }
  }

  Future<String?> bulkDelete(List<String> uuids) async {
    if (_taskManager == null) return null;
    if (uuids.isEmpty) return null;
    try {
      await _taskManager!.deleteTasks(uuidStrs: uuids);
      return null;
    } catch (e) {
      return 'Bulk delete failed';
    }
  }

  Future<String?> setRecurrenceLimit(int limit) async {
    if (_taskManager == null) return 'No profile loaded';
    final normalized = limit < 0 ? 0 : limit;
    try {
      await _taskManager!.setRecurrenceLimit(limit: BigInt.from(normalized));
      _recurrenceLimit = normalized;
      return null;
    } catch (e) {
      return e.toString();
    }
  }

  // --- import/export
  Future<String?> exportData({required bool includeDeleted}) async {
    if (_taskManager == null) return null;
    return await _taskManager!.exportTasks(includeDeleted: includeDeleted);
  }

  Future<String?> importData(String jsonData) async {
    if (_taskManager == null) return "Profile not loaded";
    try {
      await _taskManager!.importTasks(jsonData: jsonData);
      return null;
    } catch (e) {
      return e.toString();
    }
  }

  // --- dispose
  void dispose() {
    _taskByUuid.clear();
  }
}
