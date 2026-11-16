import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taskdroid/widgets/tag_input.dart';

import 'test_theme.dart';

Widget _host({
  required Set<String> available,
  required ValueChanged<List<String>> onChanged,
  List<String> initial = const [],
}) {
  return MaterialApp(
    theme: testTheme(),
    home: Scaffold(
      body: _Host(
        available: available,
        initial: initial,
        onChanged: onChanged,
      ),
    ),
  );
}

class _Host extends StatefulWidget {
  const _Host({
    required this.available,
    required this.initial,
    required this.onChanged,
  });

  final Set<String> available;
  final List<String> initial;
  final ValueChanged<List<String>> onChanged;

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  late List<String> _selected = List.of(widget.initial);

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 500,
      child: TagInput(
        selectedTags: _selected,
        availableTags: widget.available,
        onChanged: (tags) {
          setState(() => _selected = tags);
          widget.onChanged(tags);
        },
      ),
    );
  }
}

void main() {
  testWidgets('suggestions are listed inline and filter as you type', (
    tester,
  ) async {
    var selected = <String>[];

    await tester.pumpWidget(
      _host(
        available: {'errands', 'weekend', 'hardware'},
        onChanged: (tags) => selected = tags,
      ),
    );

    expect(find.text('errands'), findsOneWidget);
    expect(find.text('weekend'), findsOneWidget);
    expect(find.text('hardware'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'end');
    await tester.pump();

    expect(find.text('weekend'), findsOneWidget);
    expect(find.text('errands'), findsNothing);
    expect(find.text('hardware'), findsNothing);

    await tester.tap(find.text('weekend'));
    await tester.pump();

    expect(selected, ['weekend']);
    expect(find.widgetWithText(InputChip, 'weekend'), findsOneWidget);
    // The added tag is no longer offered as a suggestion.
    expect(find.text('errands'), findsOneWidget);
    expect(find.text('hardware'), findsOneWidget);
  });

  testWidgets('shows an empty state when there are no tags at all', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(available: const {}, onChanged: (_) {}),
    );

    expect(find.text('No tags yet'), findsOneWidget);
  });
}
