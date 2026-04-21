import 'package:flutter_test/flutter_test.dart';
import 'package:taskdroid/services/task_query_language.dart';
import 'package:taskdroid/src/rust/api.dart';

void main() {
  group('Task query language', () {
    test('supports implicit AND with tag and project', () {
      final query = parseTaskQuery('+home project:area.personal', _now);
      final task = _task(tags: ['home'], project: 'area.personal.sub');

      expect(query.matches(task, _now), isTrue);
    });

    test('supports OR expressions and grouping', () {
      final query = parseTaskQuery('(project:work or +urgent) +home', _now);
      final task = _task(tags: ['home', 'urgent'], project: 'misc');

      expect(query.matches(task, _now), isTrue);
    });

    test('supports negation prefix', () {
      final query = parseTaskQuery('+home -project:work', _now);
      final task = _task(tags: ['home'], project: 'work');

      expect(query.matches(task, _now), isFalse);
    });

    test('explicit non-pending status clauses broaden display scope', () {
      final query = parseTaskQuery('status:completed', _now);
      final task = _task(status: TaskStatus.completed);

      expect(query.usesExplicitStatusScope, isTrue);
      expect(query.matches(task, _now), isTrue);
    });

    test('negative-only status clauses stay in queue scope', () {
      final query = parseTaskQuery('-COMPLETED -DELETED', _now);

      expect(query.usesExplicitStatusScope, isFalse);
    });

    test('pending status clauses stay in queue scope', () {
      final query = parseTaskQuery('status:pending', _now);

      expect(query.usesExplicitStatusScope, isFalse);
    });

    test('supports compatibility aliases and symbolic operators', () {
      final query = parseTaskQuery('pro:work && !blocked', _now);
      final task = _task(project: 'work', isBlocked: false);

      expect(query.matches(task, _now), isTrue);
    });

    test('supports +COMPLETED status style syntax', () {
      final query = parseTaskQuery('+COMPLETED', _now);
      final task = _task(status: TaskStatus.completed);

      expect(query.usesExplicitStatusScope, isTrue);
      expect(query.matches(task, _now), isTrue);
    });

    test('date clauses support before and relative date keywords', () {
      final query = parseTaskQuery('due.before:today', _now);
      final task = _task(due: '2026-01-09T12:00:00Z');

      expect(query.matches(task, _now), isTrue);
    });

    test('ready flag excludes future scheduled tasks', () {
      final query = parseTaskQuery('+ready', _now);
      final task = _task(
        status: TaskStatus.pending,
        scheduled: '2026-01-12T00:00:00Z',
      );

      expect(query.matches(task, _now), isFalse);
    });

    test('supports wait:someday shorthand', () {
      final query = parseTaskQuery('wait:someday', _now);
      final task = _task(wait: '2026-02-20T00:00:00Z');

      expect(query.matches(task, _now), isTrue);
    });

    test('supports comparison date operators and eow keyword', () {
      final query = parseTaskQuery('due<=eow', _now);
      final task = _task(due: '2026-01-11T00:00:00Z');

      expect(query.matches(task, _now), isTrue);
    });

    test('surfaces parse issues for malformed query', () {
      final query = parseTaskQuery('(project:work or', _now);

      expect(query.hasErrors, isTrue);
      expect(query.issues, isNotEmpty);
    });

    test('taskwarrior-style query examples parse without errors', () {
      const examples = [
        '(+ACTIVE or +DUE or +OVERDUE) +READY',
        '(+READY +PROJECT) -DUE -DUETODAY -OVERDUE -ACTIVE',
        '(-COMPLETED -DELETED wait:someday)',
        '-COMPLETED -DELETED -TEMPLATE',
        '(+COMPLETED)',
        '-COMPLETED -DELETED -PROJECT',
      ];

      for (final example in examples) {
        final parsed = parseTaskQuery(example, _now);
        expect(parsed.hasErrors, isFalse, reason: example);
        expect(parsed.termCount, greaterThan(0), reason: example);
      }
    });
  });
}

final DateTime _now = DateTime.utc(2026, 1, 10, 12);

TaskView _task({
  List<String>? tags,
  TaskStatus status = TaskStatus.pending,
  String? due,
  String? wait,
  String? scheduled,
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
    scheduled: scheduled,
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
