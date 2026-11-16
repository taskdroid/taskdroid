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

  testWidgets('showAppSheet lifts the sheet above the keyboard', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        theme: testTheme(),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showAppSheet<void>(
                context,
                scrollControlled: true,
                heightFactor: 0.5,
                builder: (_) => const Text('hi'),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('hi'), findsOneWidget);
    // The view is 800 tall and the keyboard covers the bottom 300, so the sheet
    // has to end at 500 instead of hugging the bottom of the screen, and a
    // heightFactor of 0.5 has to be half of what is left (minus the drag
    // handle), not half of 800.
    final sheetContent = find.byType(FractionallySizedBox);
    expect(
      tester.getBottomLeft(sheetContent).dy,
      moreOrLessEquals(500, epsilon: 0.5),
    );
    expect(tester.getSize(sheetContent).height, lessThan(250));
    expect(tester.getBottomLeft(find.text('hi')).dy, lessThanOrEqualTo(500));
  });

  testWidgets('tapping dead space in a sheet dismisses the keyboard', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: testTheme(),
        // The app installs the tap-to-dismiss layer once, at the root; the
        // sheet does not add one of its own.
        builder: (context, child) => AppTapToDismiss(child: child),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showAppSheet<void>(
                context,
                builder: (_) => const Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Padding(
                      padding: EdgeInsets.all(AppSpace.lg),
                      child: TextField(),
                    ),
                    SizedBox(
                      key: Key('dead'),
                      width: double.infinity,
                      height: 100,
                    ),
                  ],
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

    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();
    expect(
      tester.widget<EditableText>(find.byType(EditableText)).focusNode.hasFocus,
      isTrue,
    );

    await tester.tapAt(tester.getCenter(find.byKey(const Key('dead'))));
    await tester.pumpAndSettle();
    expect(
      tester.widget<EditableText>(find.byType(EditableText)).focusNode.hasFocus,
      isFalse,
    );
  });
}
