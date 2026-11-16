import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:taskdroid/models/filter_tab.dart';
import 'package:taskdroid/providers/app_state.dart';
import 'package:taskdroid/services/task_query_language.dart';
import 'package:taskdroid/views/home.dart';

import 'test_theme.dart';

Widget _host({
  required AppState appState,
  required ValueChanged<String> onSearchChanged,
}) {
  return MaterialApp(
    theme: testTheme(),
    home: ChangeNotifierProvider<AppState>.value(
      value: appState,
      child: Scaffold(
        body: TaskSearchAndFiltersRow(
          searchQuery: '',
          parsedQuery: parseTaskQuery(''),
          onSearchChanged: onSearchChanged,
          allTags: const {},
          allProjects: const {},
          includeTags: const {},
          excludeTags: const {},
          tagMatchMode: FilterMatchMode.and,
          includeProjects: const {},
          excludeProjects: const {},
          projectMatchMode: FilterMatchMode.and,
          onOpenTags: () {},
          onOpenProjects: () {},
          onRemoveTag: (_) {},
          onRemoveExcludedTag: (_) {},
          onRemoveProject: (_) {},
          onRemoveExcludedProject: (_) {},
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('tag and project chips are hidden when filters are turned off', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final appState = AppState();

    await tester.pumpWidget(_host(appState: appState, onSearchChanged: (_) {}));
    await tester.pump();

    expect(find.widgetWithText(ActionChip, 'Tags'), findsOneWidget);
    expect(find.widgetWithText(ActionChip, 'Projects'), findsOneWidget);

    await appState.setShowTagProjectFilters(false);
    await tester.pump();

    expect(find.widgetWithText(ActionChip, 'Tags'), findsNothing);
    expect(find.widgetWithText(ActionChip, 'Projects'), findsNothing);
    // The search field itself stays available.
    expect(find.byType(TextField), findsOneWidget);
  });

  testWidgets('tapping a syntax example fills the search field', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final appState = AppState();
    String? changed;

    await tester.pumpWidget(
      _host(appState: appState, onSearchChanged: (value) => changed = value),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.search));
    await tester.pumpAndSettle();
    expect(find.text('Search syntax'), findsOneWidget);

    final exampleChip = find.widgetWithText(ActionChip, '+home project:work');
    await tester.ensureVisible(exampleChip);
    await tester.pumpAndSettle();
    await tester.tap(exampleChip);
    await tester.pumpAndSettle();

    expect(changed, '+home project:work');
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '+home project:work',
    );
    expect(find.text('Search syntax'), findsNothing);
  });
}
