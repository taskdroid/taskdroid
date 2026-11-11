import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taskdroid/widgets/common/app_sheet.dart';
import 'package:taskdroid/widgets/context_editor_sheet.dart';

import 'test_theme.dart';

void main() {
  testWidgets('Save is disabled until a name is typed, then pops the values', (
    tester,
  ) async {
    Map<String, String>? result;

    await tester.pumpWidget(
      MaterialApp(
        theme: testTheme(),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                result = await showAppSheet<Map<String, String>>(
                  context,
                  scrollControlled: true,
                  builder: (_) => const ContextEditorSheet(),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('Define Context'), findsOneWidget);
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNull,
    );

    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), 'work');
    await tester.pump();

    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNotNull,
    );

    await tester.enterText(fields.at(1), '+work');
    await tester.enterText(fields.at(2), '+work project:Work');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(result, {
      'name': 'work',
      'query': '+work',
      'write': '+work project:Work',
    });
    expect(find.byType(ContextEditorSheet), findsNothing);
  });

  testWidgets('an existing context opens as Edit Context with Cancel', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: testTheme(),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showAppSheet<Map<String, String>>(
                context,
                scrollControlled: true,
                builder: (_) => const ContextEditorSheet(
                  initialName: 'home',
                  initialQuery: '+home',
                  initialWrite: '',
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('Edit Context'), findsOneWidget);
    expect(find.text('Save'), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.byType(ContextEditorSheet), findsNothing);
  });
}
