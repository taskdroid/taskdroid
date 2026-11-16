import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:taskdroid/services/task_repository.dart';
import 'package:taskdroid/src/rust/api.dart';

TaskView _task({required String uuid, required String description}) {
  return TaskView(
    uuid: uuid,
    description: description,
    status: TaskStatus.pending,
    project: null,
    priority: null,
    tags: const [],
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
  final List<TaskFilter> filters = [];
  final List<Completer<TaskListResult>> _pending = [];

  Future<TaskListResult> list(TaskFilter filter) {
    filters.add(filter);
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

Future<void> _settle() => Future<void>.delayed(Duration.zero);

void main() {
  test('a superseded load resolves only after the queued reload', () async {
    final source = _DelayedTaskSource();
    final repository = TaskRepository(listTasks: source.list);

    var firstFinished = false;
    final first = repository
        .refreshPendingTasks('first')
        .whenComplete(() => firstFinished = true);

    await _settle();
    expect(source.filters, hasLength(1));
    expect(source.filters.single.searchTerm, 'first');
    expect(repository.isLoading, isTrue);

    // Second query while the first is still in flight: latest query wins.
    final second = repository.refreshPendingTasks('second');
    await _settle();

    // The stale load finishes; its result is dropped and a reload queued.
    source.complete(0, [_task(uuid: 'stale', description: 'stale')]);
    await _settle();

    expect(
      firstFinished,
      isFalse,
      reason: 'the first call must wait for the queued reload',
    );
    expect(source.filters, hasLength(2));
    expect(source.filters.last.searchTerm, 'second');
    expect(repository.readyTasks, isEmpty);
    expect(repository.isLoading, isTrue);

    source.complete(1, [_task(uuid: 'fresh', description: 'fresh')]);
    await first;
    await second;

    expect(firstFinished, isTrue);
    expect(repository.readyTasks.map((task) => task.uuid), ['fresh']);
    expect(repository.isLoading, isFalse);
    expect(repository.error, isNull);
  });

  test('the final queued reload surfaces its own error', () async {
    final source = _DelayedTaskSource();
    final repository = TaskRepository(listTasks: source.list);

    final first = repository.refreshPendingTasks('first');
    await _settle();
    final second = repository.refreshPendingTasks('second');
    await _settle();

    source.complete(0, [_task(uuid: 'stale', description: 'stale')]);
    await _settle();

    source._pending[1].completeError(StateError('boom'));
    await first;
    await second;

    expect(repository.isLoading, isFalse);
    expect(repository.error, 'Failed to sync with local database.');
  });
}
