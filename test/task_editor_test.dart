import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:taskdroid/providers/task_state.dart';
import 'package:taskdroid/src/rust/api.dart';
import 'package:taskdroid/widgets/common/app_attribute_chip.dart';
import 'package:taskdroid/widgets/common/app_value_row.dart';
import 'package:taskdroid/widgets/task_editor.dart';

import 'test_theme.dart';

/// Opens the editor sheet from a button so `Navigator.pop` has somewhere to go.
Future<void> _openEditor(WidgetTester tester) async {
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

Widget _host({required void Function(BuildContext) onOpen}) {
  return ChangeNotifierProvider<TaskState>(
    create: (_) => TaskState(),
    child: MaterialApp(
      theme: testTheme(),
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => onOpen(context),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('Create stays disabled until a description is typed', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(onOpen: (context) => showTaskEditorSheet(context)),
    );
    await _openEditor(tester);

    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNull,
    );

    await tester.enterText(find.byType(TextField), 'Buy milk');
    await tester.pump();

    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNotNull,
    );
  });

  testWidgets('typing a description and tapping Create pops the result', (
    tester,
  ) async {
    TaskEditorResult? result;
    await tester.pumpWidget(
      _host(
        onOpen: (context) async {
          result = await showTaskEditorSheet(context);
        },
      ),
    );
    await _openEditor(tester);

    await tester.enterText(find.byType(TextField), 'Buy milk');
    await tester.pump();
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();

    expect(result, isNotNull);
    expect(result!.description, 'Buy milk');
    expect(find.byType(TaskEditor), findsNothing);
  });

  testWidgets('Done on the keyboard finishes the description without saving', (
    tester,
  ) async {
    TaskEditorResult? result;
    await tester.pumpWidget(
      _host(
        onOpen: (context) async {
          result = await showTaskEditorSheet(context);
        },
      ),
    );
    await _openEditor(tester);

    await tester.enterText(find.byType(TextField), 'Buy milk');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(result, isNull);
    expect(find.byType(TaskEditor), findsOneWidget);
    expect(find.text('Buy milk'), findsOneWidget);
  });

  testWidgets('the priority chip shows the picked priority', (tester) async {
    TaskEditorResult? result;
    await tester.pumpWidget(
      _host(
        onOpen: (context) async {
          result = await showTaskEditorSheet(context);
        },
      ),
    );
    await _openEditor(tester);

    expect(find.text('Priority'), findsOneWidget);

    await tester.tap(find.text('Priority'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('High'));
    await tester.pumpAndSettle();

    expect(find.text('High'), findsOneWidget);

    await tester.enterText(find.byType(TextField).first, 'Buy milk');
    await tester.pump();
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();

    expect(result!.priority, 'H');
  });

  testWidgets('Advanced is collapsed for a new task', (tester) async {
    await tester.pumpWidget(
      _host(onOpen: (context) => showTaskEditorSheet(context)),
    );
    await _openEditor(tester);

    expect(find.text('Advanced'), findsOneWidget);
    expect(find.text('Duration (minutes)'), findsNothing);

    await tester.tap(find.text('Advanced'));
    await tester.pumpAndSettle();

    expect(find.text('Duration (minutes)'), findsOneWidget);
  });

  testWidgets('Tags gets its own chip row and the description shows two lines', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(onOpen: (context) => showTaskEditorSheet(context)),
    );
    await _openEditor(tester);

    final project = tester.getRect(find.text('Project'));
    final priority = tester.getRect(find.text('Priority'));
    final tags = tester.getRect(find.text('Tags'));

    expect(priority.top, project.top);
    expect(tags.top, greaterThan(priority.bottom));

    // Tags fill their row; the description and the tags chip share the sheet's
    // content width.
    final tagsChip = find.widgetWithText(AppAttributeChip, 'Tags');
    final description = find.byType(TextField).first;
    expect(
      tester.getSize(tagsChip).width,
      closeTo(tester.getSize(description).width, 0.5),
    );

    expect(tester.getSize(description).height, greaterThanOrEqualTo(50));
  });

  testWidgets('the priority chip keeps its width when a priority is picked', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(onOpen: (context) => showTaskEditorSheet(context)),
    );
    await _openEditor(tester);

    final before = tester.getSize(
      find.widgetWithText(AppAttributeChip, 'Priority'),
    );

    await tester.tap(find.text('Priority'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('High'));
    await tester.pumpAndSettle();

    final after = tester.getSize(find.widgetWithText(AppAttributeChip, 'High'));
    expect(after.width, before.width);
    expect(after.height, before.height);
  });

  testWidgets('the tags sheet lists suggestions inside the sheet', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(onOpen: (context) => showTaskEditorSheet(context)),
    );
    await _openEditor(tester);

    await tester.tap(find.text('Tags'));
    await tester.pumpAndSettle();

    expect(find.text('Add a tag'), findsOneWidget);
    expect(find.text('No tags yet'), findsOneWidget);
  });

  testWidgets('dismissing the project picker keeps the editor alive', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(onOpen: (context) => showTaskEditorSheet(context)),
    );
    await _openEditor(tester);

    await tester.tap(find.text('Project'));
    await tester.pumpAndSettle();
    expect(find.text('Search or type a new project'), findsOneWidget);

    // Tapping the barrier pops the picker and runs its exit animation; the
    // picker's own state must own its controller so nothing is disposed while
    // the sheet is still on screen.
    await tester.tapAt(const Offset(400, 20));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('New Task'), findsOneWidget);
  });

  testWidgets('a dependency can be removed from the Blocked by list', (
    tester,
  ) async {
    TaskEditorResult? result;
    await tester.pumpWidget(
      _host(
        onOpen: (context) async {
          result = await showTaskEditorSheet(
            context,
            originalTask: _task(
              depends: const ['11111111-dep-0000-0000-000000000000'],
            ),
          );
        },
      ),
    );
    await _openEditor(tester);

    // A task with a dependency opens with Advanced expanded.
    final dependency = find.textContaining('Task (11111111)');
    await tester.ensureVisible(dependency);
    await tester.pumpAndSettle();
    expect(dependency, findsOneWidget);
    // The dependency row is a plain row: no "Not set" placeholder, unlike the
    // timeline rows above it.
    expect(
      find.descendant(
        of: find.ancestor(of: dependency, matching: find.byType(AppValueRow)),
        matching: find.text('Not set'),
      ),
      findsNothing,
    );

    final remove = find.byTooltip('Remove');
    await tester.ensureVisible(remove);
    await tester.pumpAndSettle();
    await tester.tap(remove);
    await tester.pumpAndSettle();

    expect(dependency, findsNothing);
    expect(find.text('No dependencies blocking this task.'), findsOneWidget);

    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(result, isNotNull);
    expect(result!.dependencies, isEmpty);
  });
}

TaskView _task({required List<String> depends}) {
  return TaskView(
    uuid: 'uuid-1',
    description: 'Ship the release',
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
    depends: depends,
    recurrence: null,
    annotations: const [],
    udas: const [],
    urgency: 1.0,
    isActive: false,
    isBlocked: true,
    isBlocking: false,
    isWaiting: false,
    parentUuid: null,
    recurrenceIndex: null,
    isRecurringTemplate: false,
    isRecurringInstance: false,
    seriesRootUuid: null,
  );
}
