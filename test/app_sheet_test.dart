import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taskdroid/theme/tokens.dart';
import 'package:taskdroid/widgets/common/app_sheet.dart';

import 'test_theme.dart';

void main() {
  testWidgets('showAppSheet takes its shape and drag handle from the theme', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: testTheme(),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () =>
                  showAppSheet<void>(context, builder: (_) => const Text('hi')),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('hi'), findsOneWidget);

    final material = tester.widget<Material>(
      find
          .descendant(
            of: find.byType(BottomSheet),
            matching: find.byType(Material),
          )
          .first,
    );
    final shape = material.shape! as RoundedRectangleBorder;
    expect(
      shape.borderRadius,
      const BorderRadius.vertical(top: Radius.circular(AppRadius.sheet)),
    );

    expect(
      Theme.of(tester.element(find.text('hi'))).bottomSheetTheme.showDragHandle,
      isTrue,
    );
    // `showModalBottomSheet` resolves the theme value onto the route and hands
    // the result to `BottomSheet`; asserting that value stays valid when
    // Material changes the handle's size or widget type.
    final sheet = tester.widget<BottomSheet>(find.byType(BottomSheet));
    expect(sheet.showDragHandle, isTrue);
  });
}
