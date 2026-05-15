import 'package:flutter/widgets.dart';
import 'package:taskdroid/services/task_query_syntax.dart';

enum TaskQuerySuggestionType { operator, field, value, flag, date }

class TaskQuerySuggestion {
  const TaskQuerySuggestion({
    required this.label,
    required this.insertText,
    required this.detail,
    required this.type,
  });

  final String label;
  final String insertText;
  final String detail;
  final TaskQuerySuggestionType type;
}

class TaskQueryCompletion {
  const TaskQueryCompletion({
    required this.text,
    required this.selectionOffset,
  });

  final String text;
  final int selectionOffset;
}

class TaskQueryAutocomplete {
  const TaskQueryAutocomplete._();

  static const int defaultLimit = 5;

  static List<TaskQuerySuggestion> suggestionsFor({
    required String query,
    required int selectionOffset,
    Iterable<String> tags = const [],
    Iterable<String> projects = const [],
    int limit = defaultLimit,
  }) {
    final token = _currentToken(query, selectionOffset);
    if (token == null || token.text.isEmpty) return const [];

    final suggestions = <TaskQuerySuggestion>[];
    final lower = token.text.toLowerCase();

    if ((lower.startsWith('+') || lower.startsWith('-')) && lower.length > 1) {
      final sign = token.text[0];
      final prefix = lower.substring(1);
      _addPrefixed(
        suggestions,
        _sortedUnique(tags).map((tag) => '$sign$tag'),
        prefix: token.text,
        detail: sign == '+' ? 'Include tag' : 'Exclude tag',
        type: TaskQuerySuggestionType.value,
      );
      _addPrefixed(
        suggestions,
        TaskQuerySyntax.statusNames.map((status) => '$sign$status'),
        prefix: '$sign$prefix',
        detail: 'Status',
        type: TaskQuerySuggestionType.value,
      );
      _addPrefixed(
        suggestions,
        TaskQuerySyntax.flagNames.map((flag) => '$sign$flag'),
        prefix: '$sign$prefix',
        detail: 'Flag',
        type: TaskQuerySuggestionType.flag,
      );
      return _rankAndLimit(suggestions, token.text, limit);
    }

    final colonIndex = token.text.indexOf(':');
    if (colonIndex > 0) {
      final rawKey = token.text.substring(0, colonIndex);
      final key = TaskQuerySyntax.canonicalKey(rawKey.toLowerCase());
      final valuePrefix = token.text.substring(colonIndex + 1);
      return _valueSuggestions(
        key: key,
        rawKey: rawKey,
        valuePrefix: valuePrefix,
        tags: tags,
        projects: projects,
        limit: limit,
      );
    }

    final dotIndex = token.text.indexOf('.');
    if (dotIndex > 0) {
      final field = token.text.substring(0, dotIndex);
      final opPrefix = token.text.substring(dotIndex + 1).toLowerCase();
      if (TaskQuerySyntax.dateFieldNames.contains(field.toLowerCase())) {
        _addPrefixed(
          suggestions,
          TaskQuerySyntax.dateOperatorNames.map((op) => '$field.$op:'),
          prefix: '$field.$opPrefix',
          detail: 'Date operator',
          type: TaskQuerySuggestionType.date,
        );
        return _rankAndLimit(suggestions, token.text, limit);
      }
    }

    _addPrefixed(
      suggestions,
      TaskQuerySyntax.logicalOperators,
      prefix: lower,
      detail: 'Operator',
      type: TaskQuerySuggestionType.operator,
    );
    _addPrefixed(
      suggestions,
      TaskQuerySyntax.fieldNames.map((field) => '$field:'),
      prefix: lower,
      detail: 'Field',
      type: TaskQuerySuggestionType.field,
    );
    _addPrefixed(
      suggestions,
      TaskQuerySyntax.statusNames,
      prefix: lower,
      detail: 'Status',
      type: TaskQuerySuggestionType.value,
    );
    _addPrefixed(
      suggestions,
      TaskQuerySyntax.flagNames,
      prefix: lower,
      detail: 'Flag',
      type: TaskQuerySuggestionType.flag,
    );

    return _rankAndLimit(suggestions, token.text, limit);
  }

  static TaskQueryCompletion applySuggestion({
    required String query,
    required int selectionOffset,
    required TaskQuerySuggestion suggestion,
  }) {
    final token = _currentToken(query, selectionOffset);
    if (token == null) {
      final nextText = suggestion.insertText;
      return TaskQueryCompletion(
        text: nextText,
        selectionOffset: nextText.length,
      );
    }

    final insertText = _insertTextFor(
      suggestion.insertText,
      query: query,
      tokenEnd: token.end,
    );
    final text = query.replaceRange(token.start, token.end, insertText);
    return TaskQueryCompletion(
      text: text,
      selectionOffset: token.start + insertText.length,
    );
  }

  static TaskQueryCompletion applySuggestionToValue({
    required TextEditingValue value,
    required TaskQuerySuggestion suggestion,
  }) {
    final selectionOffset = value.selection.baseOffset < 0
        ? value.text.length
        : value.selection.baseOffset;
    return applySuggestion(
      query: value.text,
      selectionOffset: selectionOffset,
      suggestion: suggestion,
    );
  }

  static List<TaskQuerySuggestion> _valueSuggestions({
    required String key,
    required String rawKey,
    required String valuePrefix,
    required Iterable<String> tags,
    required Iterable<String> projects,
    required int limit,
  }) {
    final suggestions = <TaskQuerySuggestion>[];
    final prefix = '$rawKey:$valuePrefix';

    switch (key) {
      case 'project':
        final normalizedPrefix = valuePrefix.trim().toLowerCase();
        final includeNone =
            normalizedPrefix.isEmpty || 'none'.startsWith(normalizedPrefix);
        final projectValues = <String>[
          ..._sortedUnique(projects),
          if (includeNone) 'none',
        ];
        _addPrefixed(
          suggestions,
          projectValues.map((project) => '$rawKey:$project'),
          prefix: prefix,
          detail: 'Project',
          type: TaskQuerySuggestionType.value,
        );
        break;
      case 'tag':
      case 'tags':
        _addPrefixed(
          suggestions,
          _sortedUnique(tags).map((tag) => '$rawKey:$tag'),
          prefix: prefix,
          detail: 'Tag',
          type: TaskQuerySuggestionType.value,
        );
        break;
      case 'status':
        _addPrefixed(
          suggestions,
          TaskQuerySyntax.statusNames.map((status) => '$rawKey:$status'),
          prefix: prefix,
          detail: 'Status',
          type: TaskQuerySuggestionType.value,
        );
        break;
      case 'priority':
        _addPrefixed(
          suggestions,
          ['H', 'M', 'L', 'none'].map((priority) => '$rawKey:$priority'),
          prefix: prefix,
          detail: 'Priority',
          type: TaskQuerySuggestionType.value,
        );
        break;
      case 'wait':
        _addPrefixed(
          suggestions,
          [
            'someday',
            ...TaskQuerySyntax.dateLiteralNames,
          ].map((literal) => '$rawKey:$literal'),
          prefix: prefix,
          detail: 'Date',
          type: TaskQuerySuggestionType.date,
        );
        break;
      case 'due':
      case 'scheduled':
      case 'entry':
      case 'modified':
      case 'start':
      case 'end':
      case 'until':
        _addPrefixed(
          suggestions,
          TaskQuerySyntax.dateLiteralNames.map((literal) => '$rawKey:$literal'),
          prefix: prefix,
          detail: 'Date',
          type: TaskQuerySuggestionType.date,
        );
        break;
    }

    return _rankAndLimit(suggestions, prefix, limit);
  }

  static void _addPrefixed(
    List<TaskQuerySuggestion> suggestions,
    Iterable<String> values, {
    required String prefix,
    required String detail,
    required TaskQuerySuggestionType type,
  }) {
    final lowerPrefix = prefix.toLowerCase();
    for (final value in values) {
      if (value.toLowerCase().startsWith(lowerPrefix) &&
          value.toLowerCase() != lowerPrefix) {
        suggestions.add(
          TaskQuerySuggestion(
            label: value,
            insertText: value,
            detail: detail,
            type: type,
          ),
        );
      }
    }
  }

  static List<TaskQuerySuggestion> _dedupeAndLimit(
    List<TaskQuerySuggestion> suggestions,
    int limit,
  ) {
    final seen = <String>{};
    final result = <TaskQuerySuggestion>[];
    for (final suggestion in suggestions) {
      final key = suggestion.insertText.toLowerCase();
      if (!seen.add(key)) continue;
      result.add(suggestion);
      if (result.length == limit) break;
    }
    return result;
  }

  static List<TaskQuerySuggestion> _rankAndLimit(
    List<TaskQuerySuggestion> suggestions,
    String token,
    int limit,
  ) {
    final deduped = _dedupeAndLimit(suggestions, suggestions.length);
    final lowerToken = token.toLowerCase();
    deduped.sort((a, b) {
      final aText = a.insertText.toLowerCase();
      final bText = b.insertText.toLowerCase();
      final aExactBoundary = _isBoundaryMatch(aText, lowerToken);
      final bExactBoundary = _isBoundaryMatch(bText, lowerToken);
      if (aExactBoundary != bExactBoundary) {
        return aExactBoundary ? -1 : 1;
      }
      return aText.compareTo(bText);
    });
    return deduped.take(limit).toList();
  }

  static bool _isBoundaryMatch(String value, String token) {
    if (!value.startsWith(token)) return false;
    if (value.length == token.length) return true;
    final next = value[token.length];
    return next == ':' || next == '.' || next == '-' || next == '_';
  }

  static List<String> _sortedUnique(Iterable<String> values) {
    final unique = {
      for (final value in values)
        if (value.trim().isNotEmpty) value.trim(),
    }.toList();
    unique.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return unique;
  }

  static String _insertTextFor(
    String value, {
    required String query,
    required int tokenEnd,
  }) {
    if (value.endsWith(':')) return value;
    if (tokenEnd < query.length && _isTokenBoundary(query[tokenEnd])) {
      return value;
    }
    return '$value ';
  }

  static _QueryToken? _currentToken(String query, int selectionOffset) {
    if (selectionOffset < 0 || selectionOffset > query.length) return null;
    var start = selectionOffset;
    var end = selectionOffset;

    while (start > 0 && !_isTokenBoundary(query[start - 1])) {
      start--;
    }
    while (end < query.length && !_isTokenBoundary(query[end])) {
      end++;
    }

    if (start == end) return null;
    return _QueryToken(
      start: start,
      end: end,
      text: query.substring(start, end),
    );
  }

  static bool _isTokenBoundary(String char) {
    return char == ' ' ||
        char == '\n' ||
        char == '\t' ||
        char == '\r' ||
        char == '(' ||
        char == ')';
  }
}

class _QueryToken {
  const _QueryToken({
    required this.start,
    required this.end,
    required this.text,
  });

  final int start;
  final int end;
  final String text;
}
