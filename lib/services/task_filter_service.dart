import 'package:taskdroid/models/filter_tab.dart';
import 'package:taskdroid/services/task_queue_service.dart';
import 'package:taskdroid/services/task_query_language.dart';
import 'package:taskdroid/src/rust/api.dart';

class TaskFilterService {
  String _searchQuery = '';
  Set<String> _includeTags = <String>{};
  Set<String> _excludeTags = <String>{};
  FilterMatchMode _tagMatchMode = FilterMatchMode.and;
  Set<String> _includeProjects = <String>{};
  Set<String> _excludeProjects = <String>{};
  FilterMatchMode _projectMatchMode = FilterMatchMode.and;

  List<TaskView>? _cachedFilteredTasks;
  String? _lastFilterKey;
  String? _lastParsedSearchQuery;
  TaskQuery? _parsedSearchQuery;

  // --- getters
  String get searchQuery => _searchQuery;
  Set<String> get includeTags => _includeTags;
  Set<String> get excludeTags => _excludeTags;
  FilterMatchMode get tagMatchMode => _tagMatchMode;
  Set<String> get includeProjects => _includeProjects;
  Set<String> get excludeProjects => _excludeProjects;
  FilterMatchMode get projectMatchMode => _projectMatchMode;

  // --- modifiers
  void setSearchQuery(String query) {
    _searchQuery = query;
    _lastParsedSearchQuery = null;
    _parsedSearchQuery = null;
    _cachedFilteredTasks = null;
  }

  void toggleTag(String tag) {
    final include = Set<String>.from(_includeTags);
    if (include.contains(tag)) {
      include.remove(tag);
    } else {
      include.add(tag);
    }
    _includeTags = include;
    _cachedFilteredTasks = null;
  }

  void toggleProject(String project) {
    final include = Set<String>.from(_includeProjects);
    if (include.contains(project)) {
      include.remove(project);
    } else {
      include.add(project);
    }
    _includeProjects = include;
    _cachedFilteredTasks = null;
  }

  void toggleExcludedTag(String tag) {
    final exclude = Set<String>.from(_excludeTags);
    final include = Set<String>.from(_includeTags);
    if (exclude.contains(tag)) {
      exclude.remove(tag);
    } else {
      exclude.add(tag);
      include.remove(tag);
    }
    _excludeTags = exclude;
    _includeTags = include;
    _cachedFilteredTasks = null;
  }

  void toggleExcludedProject(String project) {
    final exclude = Set<String>.from(_excludeProjects);
    final include = Set<String>.from(_includeProjects);
    if (exclude.contains(project)) {
      exclude.remove(project);
    } else {
      exclude.add(project);
      include.remove(project);
    }
    _excludeProjects = exclude;
    _includeProjects = include;
    _cachedFilteredTasks = null;
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
  }

  // --- query building
  String buildFilterQuery() {
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

  // quote token values for the rust query parser.
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

  // --- query parsing (cached last)
  TaskQuery parseQuery(String effectiveSearchQuery) {
    if (_parsedSearchQuery != null &&
        _lastParsedSearchQuery == effectiveSearchQuery) {
      return _parsedSearchQuery!;
    }
    final parsed = parseTaskQuery(effectiveSearchQuery);
    _lastParsedSearchQuery = effectiveSearchQuery;
    _parsedSearchQuery = parsed;
    return parsed;
  }

  // --- client-side matching
  bool matchesTaskFilters(TaskView task, DateTime nowUtc) {
    final taskTags = task.tags.map((t) => t.toLowerCase()).toSet();

    final incTags = includeTags;
    if (incTags.isNotEmpty) {
      if (tagMatchMode == FilterMatchMode.or) {
        if (!incTags.any((t) => taskTags.contains(t.toLowerCase()))) {
          return false;
        }
      } else {
        if (!incTags.every((t) => taskTags.contains(t.toLowerCase()))) {
          return false;
        }
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
        )) {
          return false;
        }
      } else {
        if (!incProjs.every(
          (p) =>
              lowerProject == p.toLowerCase() ||
              lowerProject.startsWith('${p.toLowerCase()}.'),
        )) {
          return false;
        }
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

  // --- fetch computation
  List<TaskView> getFilteredTasks({
    required List<TaskView> allTasks,
    required List<TaskView> readyTasks,
    required List<TaskView> waitingTasks,
    required List<TaskView> scheduledTasks,
    required TaskQueueView queueView,
    required String effectiveSearchQuery,
  }) {
    final parsedQuery = parseQuery(effectiveSearchQuery);
    final filterKey =
        '${queueView.name}:'
        '${_sortedStrings(includeTags).join(',')}:'
        '${_sortedStrings(excludeTags).join(',')}:'
        '${tagMatchMode.name}:'
        '${_sortedStrings(includeProjects).join(',')}:'
        '${_sortedStrings(excludeProjects).join(',')}:'
        '${projectMatchMode.name}:'
        '${parsedQuery.usesExplicitStatusScope ? 'explicit-status' : 'queue'}';

    if (_cachedFilteredTasks != null && _lastFilterKey == filterKey) {
      return _cachedFilteredTasks!;
    }

    final source = _displaySourceTasks(
      parsedQuery: parsedQuery,
      allTasks: allTasks,
      readyTasks: readyTasks,
      waitingTasks: waitingTasks,
      scheduledTasks: scheduledTasks,
      queueView: queueView,
    );
    final now = DateTime.now().toUtc();
    var filtered = source
        .where((task) => matchesTaskFilters(task, now))
        .toList();

    _cachedFilteredTasks = filtered;
    _lastFilterKey = filterKey;
    return filtered;
  }

  List<TaskView> _displaySourceTasks({
    required TaskQuery parsedQuery,
    required List<TaskView> allTasks,
    required List<TaskView> readyTasks,
    required List<TaskView> waitingTasks,
    required List<TaskView> scheduledTasks,
    required TaskQueueView queueView,
  }) {
    if (parsedQuery.usesExplicitStatusScope) {
      return allTasks;
    }
    switch (queueView) {
      case TaskQueueView.ready:
        return readyTasks;
      case TaskQueueView.waiting:
        return waitingTasks;
      case TaskQueueView.scheduled:
        return scheduledTasks;
    }
  }

  List<String> _sortedStrings(Iterable<String> values) {
    final sorted = values.toList()..sort();
    return sorted;
  }

  // --- used when context changes
  void invalidateCache() {
    _cachedFilteredTasks = null;
    _lastParsedSearchQuery = null;
    _parsedSearchQuery = null;
  }
}
