import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:taskdroid/providers/app_state.dart';
import 'package:taskdroid/providers/task_state.dart';
import 'package:taskdroid/src/rust/api.dart';
import 'package:taskdroid/widgets/task_list.dart';

import 'test_theme.dart';

TaskView _task({required List<String> tags}) {
  return TaskView(
    uuid: 'uuid-1',
    description: 'Review the pull request',
    status: TaskStatus.pending,
    project: null,
    priority: null,
    tags: tags,
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

Widget _host({
  required AppState appState,
  required TaskState taskState,
  required TaskView task,
}) {
  return MaterialApp(
    theme: testTheme(),
    home: MultiProvider(
      providers: [
        ChangeNotifierProvider<AppState>.value(value: appState),
        ChangeNotifierProvider<TaskState>.value(value: taskState),
      ],
      child: Scaffold(
        body: ListView(children: [TaskListItem(task: task)]),
      ),
    ),
  );
}

void main() {
  testWidgets('virtual tags stay hidden and only state tags can be shown', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final appState = AppState();
    final taskState = TaskState();
    final task = _task(
      tags: const [
        'home',
        'READY',
        'WAITING',
        'SCHEDULED',
        'ACTIVE',
        'BLOCKED',
        'INSTANCE',
        'PENDING',
      ],
    );

    await tester.pumpWidget(
      _host(appState: appState, taskState: taskState, task: task),
    );
    await tester.pump();

    // Default: only the real tag is listed.
    expect(find.text('home'), findsOneWidget);
    expect(find.textContaining('READY'), findsNothing);
    expect(find.textContaining('BLOCKED'), findsNothing);
    expect(find.textContaining('INSTANCE'), findsNothing);

    await appState.setShowBuiltinTagsInTaskList(true);
    await tester.pump();

    // Setting on: exactly the four state tags are revealed, ordered as stored.
    expect(
      find.text('home, READY, WAITING, SCHEDULED, ACTIVE'),
      findsOneWidget,
    );
    expect(find.textContaining('BLOCKED'), findsNothing);
    expect(find.textContaining('INSTANCE'), findsNothing);
    expect(find.textContaining('PENDING'), findsNothing);

    await appState.setShowBuiltinTagsInTaskList(false);
    await tester.pump();

    expect(find.text('home'), findsOneWidget);
    expect(find.textContaining('READY'), findsNothing);
  });
}
