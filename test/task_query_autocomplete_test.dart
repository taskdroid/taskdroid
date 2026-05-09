import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taskdroid/models/filter_tab.dart';
import 'package:taskdroid/services/task_query_autocomplete.dart';
import 'package:taskdroid/services/task_query_language.dart';
import 'package:taskdroid/views/home.dart';

void main() {
  group('Task query autocomplete', () {
    test('suggests logical operators from prefixes', () {
      final suggestions = TaskQueryAutocomplete.suggestionsFor(
        query: 'an',
        selectionOffset: 2,
      );

      expect(
        suggestions.map((suggestion) => suggestion.insertText),
        contains('and'),
      );
    });

    test('suggests field completions from prefixes', () {
      final suggestions = TaskQueryAutocomplete.suggestionsFor(
        query: 'stat',
        selectionOffset: 4,
      );

      expect(
        suggestions.map((suggestion) => suggestion.insertText),
        contains('status:'),
      );
    });

    test('suggests flag completions after plus prefix', () {
      final suggestions = TaskQueryAutocomplete.suggestionsFor(
        query: '+du',
        selectionOffset: 3,
      );

      expect(
        suggestions.map((suggestion) => suggestion.insertText),
        contains('+due'),
      );
    });

    test('suggests project values inside project field', () {
      final suggestions = TaskQueryAutocomplete.suggestionsFor(
        query: 'project:so',
        selectionOffset: 10,
        projects: ['work', 'someday', 'software'],
      );

      expect(
        suggestions.map((suggestion) => suggestion.insertText),
        containsAll(['project:someday', 'project:software']),
      );
      expect(
        suggestions.map((suggestion) => suggestion.insertText),
        isNot(contains('project:work')),
      );
      expect(
        suggestions.map((suggestion) => suggestion.insertText),
        isNot(contains('project:none')),
      );
    });

    test('suggests signed tags from existing tags', () {
      final includeSuggestions = TaskQueryAutocomplete.suggestionsFor(
        query: '+ho',
        selectionOffset: 3,
        tags: ['home', 'hotel', 'blocked'],
      );
      final excludeSuggestions = TaskQueryAutocomplete.suggestionsFor(
        query: '-ho',
        selectionOffset: 3,
        tags: ['home', 'hotel', 'blocked'],
      );

      expect(
        includeSuggestions.map((suggestion) => suggestion.insertText),
        containsAll(['+home', '+hotel']),
      );
      expect(
        excludeSuggestions.map((suggestion) => suggestion.insertText),
        containsAll(['-home', '-hotel']),
      );
    });

    test('suggests signed statuses for plus and minus prefixes', () {
      final plusSuggestions = TaskQueryAutocomplete.suggestionsFor(
        query: '+co',
        selectionOffset: 3,
      );
      final minusSuggestions = TaskQueryAutocomplete.suggestionsFor(
        query: '-de',
        selectionOffset: 3,
      );

      expect(
        plusSuggestions.map((suggestion) => suggestion.insertText),
        contains('+completed'),
      );
      expect(
        minusSuggestions.map((suggestion) => suggestion.insertText),
        contains('-deleted'),
      );
    });

    test('respects explicit suggestion limit', () {
      final suggestions = TaskQueryAutocomplete.suggestionsFor(
        query: 'project:',
        selectionOffset: 8,
        projects: ['alpha', 'beta', 'charlie', 'delta', 'echo'],
        limit: 3,
      );

      expect(suggestions.length, 3);
    });

    test('replaces only the token at the caret', () {
      const suggestion = TaskQuerySuggestion(
        label: 'and',
        insertText: 'and',
        detail: 'Operator',
        type: TaskQuerySuggestionType.operator,
      );

      final completion = TaskQueryAutocomplete.applySuggestion(
        query: 'project:work an +home',
        selectionOffset: 'project:work an'.length,
        suggestion: suggestion,
      );

      expect(completion.text, 'project:work and +home');
      expect(completion.selectionOffset, 'project:work and'.length);
    });
  });

  group('Task search widget autocomplete', () {
    testWidgets('applies a tapped suggestion through onSearchChanged', (
      tester,
    ) async {
      String? changedQuery;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TaskSearchAndFiltersRow(
              searchQuery: '',
              parsedQuery: parseTaskQuery('', DateTime.utc(2026, 1, 10)),
              onSearchChanged: (query) => changedQuery = query,
              allTags: const {},
              allProjects: const {'someday', 'software'},
              includeTags: const {},
              excludeTags: const {},
              tagMatchMode: FilterMatchMode.and,
              includeProjects: const {},
              excludeProjects: const {},
              projectMatchMode: FilterMatchMode.and,
              onOpenTags: () {},
              onOpenProjects: () {},
              onClear: () {},
              onRemoveTag: (_) {},
              onRemoveExcludedTag: (_) {},
              onRemoveProject: (_) {},
              onRemoveExcludedProject: (_) {},
            ),
          ),
        ),
      );

      await tester.enterText(find.byType(TextField), 'project:so');
      await tester.pump();
      await tester.tap(find.text('project:someday'));
      await tester.pump();

      expect(changedQuery, 'project:someday ');
    });

    testWidgets('keeps project suggestions stable when source list refreshes', (
      tester,
    ) async {
      final projects = ValueNotifier<Set<String>>({'someday', 'software'});

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ValueListenableBuilder<Set<String>>(
              valueListenable: projects,
              builder: (context, value, child) {
                return TaskSearchAndFiltersRow(
                  searchQuery: 'project:so',
                  parsedQuery: parseTaskQuery(
                    'project:so',
                    DateTime.utc(2026, 1, 10),
                  ),
                  onSearchChanged: (_) {},
                  allTags: const {},
                  allProjects: value,
                  includeTags: const {},
                  excludeTags: const {},
                  tagMatchMode: FilterMatchMode.and,
                  includeProjects: const {},
                  excludeProjects: const {},
                  projectMatchMode: FilterMatchMode.and,
                  onOpenTags: () {},
                  onOpenProjects: () {},
                  onClear: () {},
                  onRemoveTag: (_) {},
                  onRemoveExcludedTag: (_) {},
                  onRemoveProject: (_) {},
                  onRemoveExcludedProject: (_) {},
                );
              },
            ),
          ),
        ),
      );

      await tester.pump();
      expect(find.text('project:someday'), findsOneWidget);

      projects.value = {};
      await tester.pump();
      expect(find.text('project:someday'), findsOneWidget);
    });
  });
}
