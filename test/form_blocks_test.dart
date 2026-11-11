import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taskdroid/theme/tokens.dart';
import 'package:taskdroid/widgets/common/app_attribute_chip.dart';
import 'package:taskdroid/widgets/common/app_collapsible_section.dart';
import 'package:taskdroid/widgets/common/app_sheet.dart';
import 'package:taskdroid/widgets/common/app_value_row.dart';

import 'test_theme.dart';

Widget _host(Widget child) {
  return MaterialApp(
    theme: testTheme(),
    home: Scaffold(body: Center(child: child)),
  );
}

void main() {
  testWidgets('AppSheetActionBar disables the action when onAction is null', (
    tester,
  ) async {
    var cancelled = 0;

    await tester.pumpWidget(
      _host(
        AppSheetActionBar(
          title: 'New Task',
          onCancel: () => cancelled++,
          actionLabel: 'Create',
        ),
      ),
    );

    final action = tester.widget<FilledButton>(find.byType(FilledButton));
    expect(action.onPressed, isNull);

    await tester.tap(find.text('Cancel'));
    expect(cancelled, 1);
    expect(find.text('New Task'), findsOneWidget);
    expect(find.text('Create'), findsOneWidget);
  });

  testWidgets('AppSheetActionBar keeps the title clear of the buttons', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        theme: testTheme(),
        home: Scaffold(
          body: Column(
            children: [
              AppSheetActionBar(
                title: 'Filter by Projects',
                onCancel: () {},
                actionLabel: 'Apply',
                onAction: () {},
              ),
            ],
          ),
        ),
      ),
    );

    final title = tester.getRect(find.text('Filter by Projects'));
    final cancel = tester.getRect(find.widgetWithText(TextButton, 'Cancel'));
    final apply = tester.getRect(find.widgetWithText(FilledButton, 'Apply'));

    expect(title.left - cancel.right, greaterThanOrEqualTo(AppSpace.sm));
    expect(apply.left - title.right, greaterThanOrEqualTo(AppSpace.sm));
  });

  testWidgets('AppValueRow shows the placeholder, then the value', (
    tester,
  ) async {
    Widget row({String? value, VoidCallback? onClear}) => _host(
      AppValueRow(label: 'Due', value: value, onTap: () {}, onClear: onClear),
    );

    await tester.pumpWidget(row());
    expect(find.text('Not set'), findsOneWidget);
    expect(find.byIcon(Icons.chevron_right), findsOneWidget);
    expect(find.byIcon(Icons.close), findsNothing);

    await tester.pumpWidget(row(value: 'Tomorrow', onClear: () {}));
    expect(find.text('Tomorrow'), findsOneWidget);
    expect(find.text('Not set'), findsNothing);
    expect(find.byIcon(Icons.chevron_right), findsNothing);
    expect(find.byIcon(Icons.close), findsOneWidget);
  });

  testWidgets('AppAttributeChip shows label when unset and value when set', (
    tester,
  ) async {
    Widget chip({String? value, VoidCallback? onClear}) => _host(
      AppAttributeChip(
        icon: Icons.flag_outlined,
        label: 'Priority',
        value: value,
        onTap: () {},
        onClear: onClear,
      ),
    );

    await tester.pumpWidget(chip());
    expect(find.text('Priority'), findsOneWidget);
    expect(find.byIcon(Icons.close), findsNothing);

    // Set without a clear callback: value, no clear icon.
    await tester.pumpWidget(chip(value: 'High'));
    expect(find.text('High'), findsOneWidget);
    expect(find.text('Priority'), findsNothing);
    expect(find.byIcon(Icons.close), findsNothing);

    // Set with a clear callback.
    await tester.pumpWidget(chip(value: 'High', onClear: () {}));
    expect(find.byIcon(Icons.close), findsOneWidget);
  });

  testWidgets('AppCollapsibleSection hides its child until tapped', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        const AppCollapsibleSection(
          title: 'Advanced',
          child: Text('hidden body'),
        ),
      ),
    );

    expect(find.text('hidden body'), findsNothing);

    await tester.tap(find.text('Advanced'));
    await tester.pumpAndSettle();
    expect(find.text('hidden body'), findsOneWidget);

    await tester.tap(find.text('Advanced'));
    await tester.pumpAndSettle();
    expect(find.text('hidden body'), findsNothing);
  });
}
