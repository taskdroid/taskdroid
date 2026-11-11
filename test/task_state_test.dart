import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:taskdroid/models/filter_tab.dart';
import 'package:taskdroid/providers/task_state.dart';
import 'package:taskdroid/services/task_queue_service.dart';
import 'package:taskdroid/services/task_repository.dart';
import 'package:taskdroid/src/rust/api.dart';

TaskView _task({
  String description = 'task',
  List<String>? tags,
  String? project,
}) {
  return TaskView(
    uuid: 'uuid-1',
    description: description,
    status: TaskStatus.pending,
    project: project,
    priority: null,
    tags: tags ?? const [],
    entry: '2026-01-01T00:00:00Z',
    modified: '2026-01-01T00:00:00Z',
    due: null,
    wait: null,
    start: null,
    end: null,
    scheduled: null,
    until: null,
    depends: const [],
    recurrence: null,
    annotations: const [],
    udas: const [],
    urgency: 1.0,
    isActive: false,
    isBlocked: false,
    isBlocking: false,
    isWaiting: false,
    parentUuid: null,
    recurrenceIndex: null,
    isRecurringTemplate: false,
    isRecurringInstance: false,
    seriesRootUuid: null,
  );
}

/// Task source whose `listTasks` answers only when the test says so.
class _DelayedTaskSource {
  final List<Completer<TaskListResult>> _pending = [];

  Future<TaskListResult> list(TaskFilter filter) {
    final completer = Completer<TaskListResult>();
    _pending.add(completer);
    return completer.future;
  }

  void complete(int index, List<TaskView> tasks) {
    _pending[index].complete(
      TaskListResult(tasks: tasks, totalCount: BigInt.from(tasks.length)),
    );
  }
}

void main() {
  group('loading state', () {
    test('refreshPendingTasks notifies while the load is running', () async {
      final source = _DelayedTaskSource();
      final state = TaskState(
        repository: TaskRepository(listTasks: source.list),
      );
      final loadingAtNotify = <bool>[];
      state.addListener(() => loadingAtNotify.add(state.isLoading));

      final refresh = state.refreshPendingTasks();

      expect(state.isLoading, isTrue);
      expect(loadingAtNotify, [true]);

      source.complete(0, [_task()]);
      await refresh;

      expect(state.isLoading, isFalse);
      expect(loadingAtNotify, [true, false]);
    });

    test('switching pills repartitions without reloading', () async {
      final source = _DelayedTaskSource();
      final state = TaskState(
        repository: TaskRepository(listTasks: source.list),
      );
      final loading = state.refreshPendingTasks();
      source.complete(0, [_task()]);
      await loading;

      state.setQueueView(TaskQueueView.waiting);

      expect(source._pending, hasLength(1));
      expect(state.isLoading, isFalse);
      expect(state.displaySourceTasks, isEmpty);
      expect(state.allTasks, hasLength(1));
    });

    test(
      'switching tabs applies the new tab before the reload finishes',
      () async {
        final source = _DelayedTaskSource();
        final state = TaskState(
          repository: TaskRepository(listTasks: source.list),
        );
        await state.addFilterTab('All');
        await state.addFilterTab('Second');
        final firstTabId = state.filterTabs.first.id;
        expect(state.currentTab?.id, isNot(firstTabId));

        var sawLoading = false;
        state.addListener(() {
          if (state.isLoading) sawLoading = true;
        });

        await state.switchToTab(firstTabId);

        // The tab and its filtered list are live while the reload is still out.
        expect(state.currentTab?.id, firstTabId);
        expect(sawLoading, isTrue);
        expect(state.isLoading, isTrue);

        source.complete(0, [_task()]);
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);

        expect(state.isLoading, isFalse);
      },
    );
  });

  group('matchesTaskFilters', () {
    late TaskState state;

    setUp(() {
      state = TaskState();
    });

    test('returns true when no filters active', () {
      final task = _task(tags: ['home'], project: 'work');
      expect(state.matchesTaskFilters(task), isTrue);
    });

    group('tag inclusion', () {
      test('AND mode requires all included tags', () {
        state.toggleTag('home');
        state.toggleTag('work');
        final task = _task(tags: ['home', 'work']);
        expect(state.matchesTaskFilters(task), isTrue);
      });

      test('AND mode rejects task missing a tag', () {
        state.toggleTag('home');
        state.toggleTag('work');
        final task = _task(tags: ['home']);
        expect(state.matchesTaskFilters(task), isFalse);
      });

      test('OR mode matches any included tag', () {
        state.setTagFilters(
          include: {'home', 'work'},
          exclude: {},
          mode: FilterMatchMode.or,
        );
        final task = _task(tags: ['work']);
        expect(state.matchesTaskFilters(task), isTrue);
      });

      test('OR mode rejects task with no included tag', () {
        state.setTagFilters(
          include: {'home', 'work'},
          exclude: {},
          mode: FilterMatchMode.or,
        );
        final task = _task(tags: ['urgent']);
        expect(state.matchesTaskFilters(task), isFalse);
      });
    });

    group('tag exclusion', () {
      test('exclude tag filters out matching task', () {
        state.toggleExcludedTag('home');
        final task = _task(tags: ['home']);
        expect(state.matchesTaskFilters(task), isFalse);
      });

      test('exclude tag preserves task without that tag', () {
        state.toggleExcludedTag('home');
        final task = _task(tags: ['work']);
        expect(state.matchesTaskFilters(task), isTrue);
      });
    });

    group('project inclusion', () {
      test('AND mode requires all included projects (prefix match)', () {
        state.toggleProject('work');
        final task = _task(project: 'work.personal');
        expect(state.matchesTaskFilters(task), isTrue);
      });

      test('AND mode rejects non-matching project', () {
        state.toggleProject('work');
        final task = _task(project: 'personal');
        expect(state.matchesTaskFilters(task), isFalse);
      });

      test('OR mode matches any included project', () {
        state.setProjectFilters(
          include: {'work', 'personal'},
          exclude: {},
          mode: FilterMatchMode.or,
        );
        final task = _task(project: 'personal');
        expect(state.matchesTaskFilters(task), isTrue);
      });

      test('rejects task with no project when projects are included', () {
        state.toggleProject('work');
        final task = _task();
        expect(state.matchesTaskFilters(task), isFalse);
      });

      test('exact project match works', () {
        state.toggleProject('work');
        final task = _task(project: 'work');
        expect(state.matchesTaskFilters(task), isTrue);
      });
    });

    group('project exclusion', () {
      test('exclude project filters out matching task', () {
        state.toggleExcludedProject('work');
        final task = _task(project: 'work.personal');
        expect(state.matchesTaskFilters(task), isFalse);
      });

      test('exclude project preserves non-matching task', () {
        state.toggleExcludedProject('work');
        final task = _task(project: 'personal');
        expect(state.matchesTaskFilters(task), isTrue);
      });
    });

    group('combined filters', () {
      test('include tag AND include project both must match', () {
        state.toggleTag('home');
        state.toggleProject('work');
        final matching = _task(tags: ['home'], project: 'work');
        final noTag = _task(tags: [], project: 'work');
        final noProject = _task(tags: ['home'], project: 'other');
        expect(state.matchesTaskFilters(matching), isTrue);
        expect(state.matchesTaskFilters(noTag), isFalse);
        expect(state.matchesTaskFilters(noProject), isFalse);
      });

      test('exclude overrides include', () {
        state.toggleTag('home');
        state.toggleExcludedTag('home');
        final task = _task(tags: ['home']);
        expect(state.matchesTaskFilters(task), isFalse);
      });
    });
  });
}
