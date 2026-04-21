import 'package:taskdroid/models/filter_tab.dart';
import 'package:taskdroid/models/task_virtual_flags.dart';
import 'package:taskdroid/src/rust/api.dart';

class TaskFilterCriteria {
  const TaskFilterCriteria({
    required this.includeTags,
    required this.excludeTags,
    required this.tagMatchMode,
    required this.includeProjects,
    required this.excludeProjects,
    required this.projectMatchMode,
    required this.includeStatuses,
    required this.excludeStatuses,
    required this.includeFlags,
    required this.excludeFlags,
    required this.flagMatchMode,
  });

  final Set<String> includeTags;
  final Set<String> excludeTags;
  final FilterMatchMode tagMatchMode;
  final Set<String> includeProjects;
  final Set<String> excludeProjects;
  final FilterMatchMode projectMatchMode;
  final Set<TaskStatus> includeStatuses;
  final Set<TaskStatus> excludeStatuses;
  final Set<TaskVirtualFlag> includeFlags;
  final Set<TaskVirtualFlag> excludeFlags;
  final FilterMatchMode flagMatchMode;
}

bool matchesTaskFilter(
  TaskView task,
  TaskFilterCriteria criteria,
  DateTime nowUtc,
) {
  if (!_matchesStringSet(
    includeSet: criteria.includeTags,
    excludeSet: criteria.excludeTags,
    values: task.tags.toSet(),
    matchMode: criteria.tagMatchMode,
  )) {
    return false;
  }

  final projectValue = task.project == null ? <String>{} : {task.project!};
  if (!_matchesStringSet(
    includeSet: criteria.includeProjects,
    excludeSet: criteria.excludeProjects,
    values: projectValue,
    matchMode: criteria.projectMatchMode,
  )) {
    return false;
  }

  if (criteria.excludeStatuses.contains(task.status)) return false;
  if (criteria.includeStatuses.isNotEmpty &&
      !criteria.includeStatuses.contains(task.status)) {
    return false;
  }

  for (final flag in criteria.excludeFlags) {
    if (_matchesFlag(task, nowUtc, flag)) {
      return false;
    }
  }

  if (criteria.includeFlags.isEmpty) {
    return true;
  }

  if (criteria.flagMatchMode == FilterMatchMode.and) {
    return criteria.includeFlags.every(
      (flag) => _matchesFlag(task, nowUtc, flag),
    );
  }
  return criteria.includeFlags.any((flag) => _matchesFlag(task, nowUtc, flag));
}

bool _matchesStringSet({
  required Set<String> includeSet,
  required Set<String> excludeSet,
  required Set<String> values,
  required FilterMatchMode matchMode,
}) {
  for (final value in excludeSet) {
    if (values.contains(value)) return false;
  }

  if (includeSet.isEmpty) return true;
  if (matchMode == FilterMatchMode.and) {
    return includeSet.every(values.contains);
  }
  return includeSet.any(values.contains);
}

bool _matchesFlag(TaskView task, DateTime nowUtc, TaskVirtualFlag flag) {
  switch (flag) {
    case TaskVirtualFlag.ready:
      return task.isReadyAt(nowUtc);
    case TaskVirtualFlag.active:
      return task.isActive;
    case TaskVirtualFlag.due:
      return task.isDue(nowUtc);
    case TaskVirtualFlag.dueToday:
      return task.isDueToday(nowUtc);
    case TaskVirtualFlag.overdue:
      return task.isOverdue(nowUtc);
    case TaskVirtualFlag.someday:
      return task.isSomeday(nowUtc);
    case TaskVirtualFlag.project:
      return task.hasProject;
    case TaskVirtualFlag.template:
      return task.isTemplate;
  }
}
