import 'package:flutter_test/flutter_test.dart';
import 'package:taskdroid/models/profile.dart';
import 'package:taskdroid/models/filter_tab.dart';
import 'package:taskdroid/models/task_virtual_flags.dart';
import 'package:taskdroid/services/task_filter_evaluator.dart';
import 'package:taskdroid/src/rust/api.dart';

void main() {
  group('Profile model', () {
    test('toJson and fromJson roundtrip', () {
      final profile = Profile(
        id: 'test-id',
        name: 'Work',
        uuid: 'abc-123',
        secret: 's3cret',
        serverUrl: 'https://sync.example.com',
        calendarSync: true,
      );

      final json = profile.toJson();
      final restored = Profile.fromJson(json);

      expect(restored.id, profile.id);
      expect(restored.name, profile.name);
      expect(restored.uuid, profile.uuid);
      expect(restored.secret, profile.secret);
      expect(restored.serverUrl, profile.serverUrl);
      expect(restored.calendarSync, profile.calendarSync);
    });

    test('copyWith updates fields', () {
      final profile = Profile(
        id: 'id',
        name: 'Original',
        uuid: 'uuid',
        secret: 'secret',
        serverUrl: 'url',
      );

      final updated = profile.copyWith(name: 'Updated', calendarSync: true);
      expect(updated.name, 'Updated');
      expect(updated.calendarSync, true);
      expect(updated.id, profile.id);
    });

    test('fromJson handles missing fields gracefully', () {
      final profile = Profile.fromJson({'id': 'x'});
      expect(profile.id, 'x');
      expect(profile.name, '');
      expect(profile.calendarSync, false);
    });
  });

  group('FilterTab model', () {
    test('toJson and fromJson roundtrip', () {
      final tab = FilterTab(
        id: 'tab-1',
        name: 'Urgent',
        searchQuery: 'important',
        selectedTags: {'urgent', 'work'},
        selectedProjects: {'project-a'},
      );

      final json = tab.toJson();
      final restored = FilterTab.fromJson(json);

      expect(restored.id, tab.id);
      expect(restored.name, tab.name);
      expect(restored.searchQuery, tab.searchQuery);
      expect(restored.selectedTags, tab.selectedTags);
      expect(restored.selectedProjects, tab.selectedProjects);
    });

    test('copyWith updates fields', () {
      final tab = FilterTab(id: '1', name: 'All');
      final updated = tab.copyWith(name: 'Renamed', searchQuery: 'test');
      expect(updated.name, 'Renamed');
      expect(updated.searchQuery, 'test');
      expect(updated.id, '1');
    });

    test('defaults are correct', () {
      final tab = FilterTab(id: '1', name: 'Test');
      expect(tab.searchQuery, '');
      expect(tab.selectedTags, isEmpty);
      expect(tab.selectedProjects, isEmpty);
      expect(tab.includeTags, isNull);
      expect(tab.excludeTags, isNull);
      expect(tab.includeFlags, isNull);
    });

    test('supports structured filters roundtrip', () {
      final tab = FilterTab(
        id: 'tab-2',
        name: 'Now',
        includeTags: {'READY', 'ACTIVE'},
        excludeTags: {'OVERDUE'},
        tagMatchMode: FilterMatchMode.or,
        includeProjects: {'work'},
        excludeProjects: {'archived'},
        projectMatchMode: FilterMatchMode.and,
        includeStatuses: {'pending', 'completed'},
        excludeStatuses: {'deleted'},
        includeFlags: {'dueToday', 'active'},
        excludeFlags: {'template'},
        flagMatchMode: FilterMatchMode.or,
      );

      final restored = FilterTab.fromJson(tab.toJson());

      expect(restored.includeTags, tab.includeTags);
      expect(restored.excludeTags, tab.excludeTags);
      expect(restored.tagMatchMode, FilterMatchMode.or);
      expect(restored.includeProjects, tab.includeProjects);
      expect(restored.excludeProjects, tab.excludeProjects);
      expect(restored.includeStatuses, tab.includeStatuses);
      expect(restored.excludeStatuses, tab.excludeStatuses);
      expect(restored.includeFlags, tab.includeFlags);
      expect(restored.excludeFlags, tab.excludeFlags);
      expect(restored.flagMatchMode, FilterMatchMode.or);
    });
  });

  group('Task filter evaluator', () {
    test('include tags with OR mode matches if any tag exists', () {
      final task = _task(tags: ['READY']);
      final criteria = TaskFilterCriteria(
        includeTags: {'READY', 'ACTIVE'},
        excludeTags: {},
        tagMatchMode: FilterMatchMode.or,
        includeProjects: {},
        excludeProjects: {},
        projectMatchMode: FilterMatchMode.and,
        includeStatuses: {},
        excludeStatuses: {},
        includeFlags: {},
        excludeFlags: {},
        flagMatchMode: FilterMatchMode.and,
      );

      expect(
        matchesTaskFilter(task, criteria, DateTime.utc(2026, 1, 10)),
        isTrue,
      );
    });

    test('exclude tags removes matching tasks', () {
      final task = _task(tags: ['OVERDUE']);
      final criteria = TaskFilterCriteria(
        includeTags: {},
        excludeTags: {'OVERDUE'},
        tagMatchMode: FilterMatchMode.and,
        includeProjects: {},
        excludeProjects: {},
        projectMatchMode: FilterMatchMode.and,
        includeStatuses: {},
        excludeStatuses: {},
        includeFlags: {},
        excludeFlags: {},
        flagMatchMode: FilterMatchMode.and,
      );

      expect(
        matchesTaskFilter(task, criteria, DateTime.utc(2026, 1, 10)),
        isFalse,
      );
    });

    test('include overdue flag evaluates against due date', () {
      final task = _task(due: '2026-01-01T00:00:00Z');
      final criteria = TaskFilterCriteria(
        includeTags: {},
        excludeTags: {},
        tagMatchMode: FilterMatchMode.and,
        includeProjects: {},
        excludeProjects: {},
        projectMatchMode: FilterMatchMode.and,
        includeStatuses: {},
        excludeStatuses: {},
        includeFlags: {TaskVirtualFlag.overdue},
        excludeFlags: {},
        flagMatchMode: FilterMatchMode.and,
      );

      expect(
        matchesTaskFilter(task, criteria, DateTime.utc(2026, 1, 10)),
        isTrue,
      );
    });

    test('isSomeday uses wait > today+30d', () {
      final task = _task(wait: '2026-02-15T00:00:00Z');
      final now = DateTime.utc(2026, 1, 10);
      expect(task.isSomeday(now), isTrue);
    });

    test('status filters include completed for logbook style', () {
      final task = _task(status: TaskStatus.completed);
      final criteria = TaskFilterCriteria(
        includeTags: {},
        excludeTags: {},
        tagMatchMode: FilterMatchMode.and,
        includeProjects: {},
        excludeProjects: {},
        projectMatchMode: FilterMatchMode.and,
        includeStatuses: {TaskStatus.completed},
        excludeStatuses: {},
        includeFlags: {},
        excludeFlags: {},
        flagMatchMode: FilterMatchMode.and,
      );

      expect(
        matchesTaskFilter(task, criteria, DateTime.utc(2026, 1, 10)),
        isTrue,
      );
    });
  });
}

TaskView _task({
  List<String>? tags,
  TaskStatus status = TaskStatus.pending,
  String? due,
  String? wait,
  String? project,
  bool isActive = false,
  bool isBlocked = false,
  bool isWaiting = false,
  bool isRecurringTemplate = false,
}) {
  return TaskView(
    uuid: 'uuid-1',
    description: 'Task',
    status: status,
    project: project,
    priority: null,
    tags: tags ?? const [],
    entry: '2026-01-01T00:00:00Z',
    modified: '2026-01-01T00:00:00Z',
    due: due,
    wait: wait,
    start: null,
    end: null,
    scheduled: null,
    until: null,
    depends: const [],
    recurrence: null,
    annotations: const [],
    udas: const [],
    urgency: 1,
    isActive: isActive,
    isBlocked: isBlocked,
    isBlocking: false,
    isWaiting: isWaiting,
    parentUuid: null,
    recurrenceIndex: null,
    isRecurringTemplate: isRecurringTemplate,
    isRecurringInstance: false,
    seriesRootUuid: null,
  );
}
