import 'package:taskdroid/models/task_virtual_flags.dart';
import 'package:taskdroid/services/task_query_syntax.dart';
import 'package:taskdroid/src/rust/api.dart';

enum TaskQueryDateField {
  due,
  wait,
  scheduled,
  entry,
  modified,
  start,
  end,
  until,
}

enum TaskQueryDateOp { before, beforeEq, after, afterEq, on, none, any }

enum TaskQueryFlag {
  ready,
  active,
  due,
  dueToday,
  overdue,
  someday,
  project,
  template,
  blocked,
  blocking,
  waiting,
}

enum TaskQueryIssueSeverity { warning, error }

class TaskQueryIssue {
  const TaskQueryIssue({required this.message, required this.severity});

  final String message;
  final TaskQueryIssueSeverity severity;
}

sealed class TaskQueryExpr {
  const TaskQueryExpr();
}

class TaskQueryAnd extends TaskQueryExpr {
  const TaskQueryAnd(this.children);

  final List<TaskQueryExpr> children;
}

class TaskQueryOr extends TaskQueryExpr {
  const TaskQueryOr(this.children);

  final List<TaskQueryExpr> children;
}

class TaskQueryNot extends TaskQueryExpr {
  const TaskQueryNot(this.child);

  final TaskQueryExpr child;
}

class TaskQueryTermExpr extends TaskQueryExpr {
  const TaskQueryTermExpr(this.term);

  final TaskQueryTerm term;
}

class TaskQueryTerm {
  const TaskQueryTerm._({
    this.text,
    this.tag,
    this.project,
    this.status,
    this.flag,
    this.priority,
    this.uuidPrefix,
    this.udaKey,
    this.udaValue,
    this.dateField,
    this.dateOp,
    this.dateValue,
  });

  factory TaskQueryTerm.text(String text) => TaskQueryTerm._(text: text);
  factory TaskQueryTerm.tag(String tag) => TaskQueryTerm._(tag: tag);
  factory TaskQueryTerm.project(String project) =>
      TaskQueryTerm._(project: project);
  factory TaskQueryTerm.status(TaskStatus status) =>
      TaskQueryTerm._(status: status);
  factory TaskQueryTerm.flag(TaskQueryFlag flag) => TaskQueryTerm._(flag: flag);
  factory TaskQueryTerm.priority(String priority) =>
      TaskQueryTerm._(priority: priority);
  factory TaskQueryTerm.uuidPrefix(String uuidPrefix) =>
      TaskQueryTerm._(uuidPrefix: uuidPrefix);
  factory TaskQueryTerm.uda(String key, String value) =>
      TaskQueryTerm._(udaKey: key, udaValue: value);
  factory TaskQueryTerm.date({
    required TaskQueryDateField field,
    required TaskQueryDateOp op,
    DateTime? value,
  }) => TaskQueryTerm._(dateField: field, dateOp: op, dateValue: value);

  final String? text;
  final String? tag;
  final String? project;
  final TaskStatus? status;
  final TaskQueryFlag? flag;
  final String? priority;
  final String? uuidPrefix;
  final String? udaKey;
  final String? udaValue;
  final TaskQueryDateField? dateField;
  final TaskQueryDateOp? dateOp;
  final DateTime? dateValue;
}

class TaskQuery {
  const TaskQuery({
    required this.originalInput,
    required this.expression,
    required this.usesExplicitStatusScope,
    required this.issues,
    required this.termCount,
    required this.isAdvanced,
  });

  final String originalInput;
  final TaskQueryExpr? expression;
  final bool usesExplicitStatusScope;
  final List<TaskQueryIssue> issues;
  final int termCount;
  final bool isAdvanced;

  bool get hasErrors =>
      issues.any((issue) => issue.severity == TaskQueryIssueSeverity.error);

  bool matches(TaskView task, DateTime nowUtc) {
    final expr = expression;
    if (expr == null) return true;
    return _evaluateExpr(expr, task, nowUtc);
  }
}

TaskQuery parseTaskQuery(String input, DateTime nowUtc) {
  final trimmed = input.trim();
  if (trimmed.isEmpty) {
    return const TaskQuery(
      originalInput: '',
      expression: null,
      usesExplicitStatusScope: false,
      issues: [],
      termCount: 0,
      isAdvanced: false,
    );
  }

  final tokens = _mergeColonTokens(_tokenizeQuery(trimmed));
  final parser = _TaskQueryParser(tokens, nowUtc);
  final expression = parser.parse();

  return TaskQuery(
    originalInput: input,
    expression: expression,
    usesExplicitStatusScope: _usesExplicitStatusScope(expression),
    issues: parser.issues,
    termCount: _countTerms(expression),
    isAdvanced: _isAdvancedExpression(expression),
  );
}

class _TaskQueryParser {
  _TaskQueryParser(this._tokens, this._nowUtc);

  final List<String> _tokens;
  final DateTime _nowUtc;
  final List<TaskQueryIssue> issues = [];
  int _index = 0;

  TaskQueryExpr? parse() {
    final expr = _parseOr();

    while (!_isAtEnd) {
      final token = _peek;
      if (token == null) break;
      if (token == ')') {
        issues.add(
          const TaskQueryIssue(
            message: 'Unmatched closing parenthesis',
            severity: TaskQueryIssueSeverity.error,
          ),
        );
      } else {
        issues.add(
          TaskQueryIssue(
            message: 'Ignored token "$token"',
            severity: TaskQueryIssueSeverity.warning,
          ),
        );
      }
      _index++;
    }

    return expr;
  }

  TaskQueryExpr? _parseOr() {
    final left = _parseAnd();
    if (left == null) return null;
    final children = <TaskQueryExpr>[left];
    while (_isAtOrKeyword()) {
      _index++;
      final rhs = _parseAnd();
      if (rhs == null) {
        issues.add(
          const TaskQueryIssue(
            message: 'Missing expression after OR',
            severity: TaskQueryIssueSeverity.error,
          ),
        );
        break;
      }
      children.add(rhs);
    }
    if (children.length == 1) return children.first;
    return TaskQueryOr(children);
  }

  TaskQueryExpr? _parseAnd() {
    final children = <TaskQueryExpr>[];
    while (!_isAtEnd) {
      if (_peek == ')' || _isAtOrKeyword()) break;
      if (_isAtAndKeyword()) {
        _index++;
        continue;
      }

      final expr = _parseUnary();
      if (expr == null) {
        _index++;
        continue;
      }
      children.add(expr);
    }
    if (children.isEmpty) return null;
    if (children.length == 1) return children.first;
    return TaskQueryAnd(children);
  }

  TaskQueryExpr? _parseUnary() {
    final token = _peek;
    if (token == null) return null;

    if (token == '(') {
      _index++;
      final inner = _parseOr();
      if (_peek == ')') {
        _index++;
      } else {
        issues.add(
          const TaskQueryIssue(
            message: 'Missing closing parenthesis',
            severity: TaskQueryIssueSeverity.error,
          ),
        );
      }
      return inner;
    }

    if (_isAtNotKeyword()) {
      _index++;
      final child = _parseUnary();
      if (child == null) {
        issues.add(
          const TaskQueryIssue(
            message: 'Missing expression after NOT',
            severity: TaskQueryIssueSeverity.error,
          ),
        );
        return null;
      }
      return TaskQueryNot(child);
    }

    if (token.startsWith('-') && token.length > 1) {
      _index++;
      final stripped = token.substring(1);
      return TaskQueryNot(TaskQueryTermExpr(_parseTerm(stripped)));
    }

    if (token.startsWith('!') && token.length > 1) {
      _index++;
      final stripped = token.substring(1);
      return TaskQueryNot(TaskQueryTermExpr(_parseTerm(stripped)));
    }

    if (token.startsWith('+') && token.length > 1) {
      _index++;
      final stripped = token.substring(1);
      return TaskQueryTermExpr(_parsePlusToken(stripped));
    }

    _index++;
    return TaskQueryTermExpr(_parseTerm(token));
  }

  TaskQueryTerm _parsePlusToken(String token) {
    final status = _parseStatus(token);
    if (status != null) return TaskQueryTerm.status(status);
    final flag = _parseFlag(token);
    if (flag != null) return TaskQueryTerm.flag(flag);
    return TaskQueryTerm.tag(token);
  }

  TaskQueryTerm _parseTerm(String token) {
    final comparison = _parseComparisonTerm(token);
    if (comparison != null) return comparison;

    final colonIndex = token.indexOf(':');
    if (colonIndex > 0) {
      final rawKey = token.substring(0, colonIndex);
      final rawValue = token.substring(colonIndex + 1);
      final key = _canonicalKey(rawKey.toLowerCase());
      final value = _stripQuotes(rawValue);

      if (key == 'project') {
        return TaskQueryTerm.project(value);
      }
      if (key == 'tag' || key == 'tags') {
        return TaskQueryTerm.tag(value);
      }
      if (key == 'status') {
        final status = _parseStatus(value);
        if (status != null) return TaskQueryTerm.status(status);
        issues.add(
          TaskQueryIssue(
            message: 'Unknown status "$value"',
            severity: TaskQueryIssueSeverity.warning,
          ),
        );
      }
      if (key == 'priority') {
        return TaskQueryTerm.priority(value);
      }
      if (key == 'uuid') {
        return TaskQueryTerm.uuidPrefix(value);
      }
      if (key.startsWith('uda.') && key.length > 4) {
        return TaskQueryTerm.uda(key.substring(4), value);
      }
      if (key == 'description' || key == 'desc') {
        return TaskQueryTerm.text(value);
      }
      if (key == 'wait' && value.toLowerCase() == 'someday') {
        return TaskQueryTerm.flag(TaskQueryFlag.someday);
      }

      final dateTerm = _parseDateTerm(key, value, _nowUtc);
      if (dateTerm != null) return dateTerm;
      final dateKey = key.contains('.')
          ? key.substring(0, key.indexOf('.'))
          : key;
      if (_dateFieldFromKey(dateKey) != null) {
        issues.add(
          TaskQueryIssue(
            message: 'Invalid date expression "$value"',
            severity: TaskQueryIssueSeverity.warning,
          ),
        );
        return TaskQueryTerm.text(token);
      }

      issues.add(
        TaskQueryIssue(
          message: 'Unknown query field "$rawKey"',
          severity: TaskQueryIssueSeverity.warning,
        ),
      );
    }

    final lower = token.toLowerCase();
    final status = _parseStatus(lower);
    if (status != null) return TaskQueryTerm.status(status);
    final flag = _parseFlag(lower);
    if (flag != null) return TaskQueryTerm.flag(flag);

    return TaskQueryTerm.text(_stripQuotes(token));
  }

  TaskQueryTerm? _parseComparisonTerm(String token) {
    final match = RegExp(
      r'^([A-Za-z][A-Za-z0-9_.]*)(<=|>=|<|>|=)(.+)$',
    ).firstMatch(token);
    if (match == null) return null;

    final key = _canonicalKey(match.group(1)!.toLowerCase());
    final opToken = match.group(2)!;
    final rawValue = _stripQuotes(match.group(3)!);

    final field = _dateFieldFromKey(key);
    if (field == null) {
      return null;
    }

    final op = switch (opToken) {
      '<' => TaskQueryDateOp.before,
      '<=' => TaskQueryDateOp.beforeEq,
      '>' => TaskQueryDateOp.after,
      '>=' => TaskQueryDateOp.afterEq,
      '=' => TaskQueryDateOp.on,
      _ => TaskQueryDateOp.on,
    };

    final dateValue = _parseDateExpression(rawValue, _nowUtc);
    if (dateValue == null) {
      issues.add(
        TaskQueryIssue(
          message: 'Invalid date expression "$rawValue"',
          severity: TaskQueryIssueSeverity.warning,
        ),
      );
      return TaskQueryTerm.text(token);
    }

    return TaskQueryTerm.date(field: field, op: op, value: dateValue);
  }

  bool get _isAtEnd => _index >= _tokens.length;
  String? get _peek => _isAtEnd ? null : _tokens[_index];

  bool _isAtOrKeyword() {
    final token = _peek;
    if (token == null) return false;
    final lower = token.toLowerCase();
    return lower == 'or' || token == '||';
  }

  bool _isAtAndKeyword() {
    final token = _peek;
    if (token == null) return false;
    final lower = token.toLowerCase();
    return lower == 'and' || token == '&&';
  }

  bool _isAtNotKeyword() {
    final token = _peek;
    if (token == null) return false;
    final lower = token.toLowerCase();
    return lower == 'not' || token == '!';
  }
}

String _canonicalKey(String key) {
  return TaskQuerySyntax.canonicalKey(key);
}

bool _usesExplicitStatusScope(TaskQueryExpr? expr, {bool isNegated = false}) {
  if (expr == null) return false;
  if (expr case TaskQueryAnd(:final children)) {
    return children.any(
      (child) => _usesExplicitStatusScope(child, isNegated: isNegated),
    );
  }
  if (expr case TaskQueryOr(:final children)) {
    return children.any(
      (child) => _usesExplicitStatusScope(child, isNegated: isNegated),
    );
  }
  if (expr case TaskQueryNot(:final child)) {
    return _usesExplicitStatusScope(child, isNegated: !isNegated);
  }
  if (expr case TaskQueryTermExpr(:final term)) {
    final status = term.status;
    return !isNegated && status != null && status != TaskStatus.pending;
  }
  return false;
}

int _countTerms(TaskQueryExpr? expr) {
  if (expr == null) return 0;
  if (expr case TaskQueryAnd(:final children)) {
    return children.fold(0, (sum, child) => sum + _countTerms(child));
  }
  if (expr case TaskQueryOr(:final children)) {
    return children.fold(0, (sum, child) => sum + _countTerms(child));
  }
  if (expr case TaskQueryNot(:final child)) {
    return _countTerms(child);
  }
  if (expr case TaskQueryTermExpr()) return 1;
  return 0;
}

bool _isAdvancedExpression(TaskQueryExpr? expr) {
  if (expr == null) return false;
  if (expr case TaskQueryAnd(:final children)) {
    return children.any(_isAdvancedExpression);
  }
  if (expr case TaskQueryOr()) {
    return true;
  }
  if (expr case TaskQueryNot()) {
    return true;
  }
  if (expr case TaskQueryTermExpr(:final term)) {
    return term.tag != null ||
        term.project != null ||
        term.status != null ||
        term.flag != null ||
        term.priority != null ||
        term.uuidPrefix != null ||
        term.udaKey != null ||
        term.dateField != null;
  }
  return false;
}

bool _evaluateExpr(TaskQueryExpr expr, TaskView task, DateTime nowUtc) {
  if (expr case TaskQueryAnd(:final children)) {
    return children.every((child) => _evaluateExpr(child, task, nowUtc));
  }
  if (expr case TaskQueryOr(:final children)) {
    return children.any((child) => _evaluateExpr(child, task, nowUtc));
  }
  if (expr case TaskQueryNot(:final child)) {
    return !_evaluateExpr(child, task, nowUtc);
  }
  if (expr case TaskQueryTermExpr(:final term)) {
    return _evaluateTerm(term, task, nowUtc);
  }
  return true;
}

bool _evaluateTerm(TaskQueryTerm term, TaskView task, DateTime nowUtc) {
  final text = term.text;
  if (text != null) {
    final query = text.toLowerCase();
    if (query.isEmpty) return true;
    return task.description.toLowerCase().contains(query) ||
        (task.project?.toLowerCase().contains(query) ?? false) ||
        task.tags.any((tag) => tag.toLowerCase().contains(query)) ||
        task.annotations.any(
          (annotation) => annotation.description.toLowerCase().contains(query),
        ) ||
        task.udas.any(
          (uda) =>
              uda.key.toLowerCase().contains(query) ||
              uda.value.toLowerCase().contains(query),
        );
  }

  final tag = term.tag;
  if (tag != null) {
    return task.tags.any((t) => _equalsIgnoreCase(t, tag));
  }

  final project = term.project;
  if (project != null) {
    final value = task.project;
    if (project.toLowerCase() == 'none') {
      return value == null || value.trim().isEmpty;
    }
    if (value == null || value.isEmpty) return false;
    final lowerProject = project.toLowerCase();
    final lowerValue = value.toLowerCase();
    return lowerValue == lowerProject ||
        lowerValue.startsWith('$lowerProject.');
  }

  final status = term.status;
  if (status != null) return task.status == status;

  final priority = term.priority;
  if (priority != null) {
    final value = task.priority ?? '';
    if (priority.toLowerCase() == 'none') {
      return value.trim().isEmpty;
    }
    return _equalsIgnoreCase(value, priority);
  }

  final uuidPrefix = term.uuidPrefix;
  if (uuidPrefix != null) {
    return task.uuid.toLowerCase().startsWith(uuidPrefix.toLowerCase());
  }

  final udaKey = term.udaKey;
  if (udaKey != null) {
    final udaValue = (term.udaValue ?? '').toLowerCase();
    for (final uda in task.udas) {
      if (_equalsIgnoreCase(uda.key, udaKey) &&
          uda.value.toLowerCase().contains(udaValue)) {
        return true;
      }
    }
    return false;
  }

  final flag = term.flag;
  if (flag != null) {
    switch (flag) {
      case TaskQueryFlag.ready:
        return task.isReadyAt(nowUtc);
      case TaskQueryFlag.active:
        return task.isActive;
      case TaskQueryFlag.due:
        return task.isDue(nowUtc);
      case TaskQueryFlag.dueToday:
        return task.isDueToday(nowUtc);
      case TaskQueryFlag.overdue:
        return task.isOverdue(nowUtc);
      case TaskQueryFlag.someday:
        return task.isSomeday(nowUtc);
      case TaskQueryFlag.project:
        return task.hasProject;
      case TaskQueryFlag.template:
        return task.isTemplate;
      case TaskQueryFlag.blocked:
        return task.isBlocked;
      case TaskQueryFlag.blocking:
        return task.isBlocking;
      case TaskQueryFlag.waiting:
        return task.isWaitingAt(nowUtc);
    }
  }

  final dateField = term.dateField;
  if (dateField != null) {
    final taskDate = _readDateField(task, dateField);
    final op = term.dateOp;
    if (op == null) return false;
    switch (op) {
      case TaskQueryDateOp.none:
        return taskDate == null;
      case TaskQueryDateOp.any:
        return taskDate != null;
      case TaskQueryDateOp.before:
        return taskDate != null &&
            term.dateValue != null &&
            taskDate.isBefore(term.dateValue!);
      case TaskQueryDateOp.beforeEq:
        return taskDate != null &&
            term.dateValue != null &&
            (taskDate.isBefore(term.dateValue!) ||
                taskDate.isAtSameMomentAs(term.dateValue!));
      case TaskQueryDateOp.after:
        return taskDate != null &&
            term.dateValue != null &&
            taskDate.isAfter(term.dateValue!);
      case TaskQueryDateOp.afterEq:
        return taskDate != null &&
            term.dateValue != null &&
            (taskDate.isAfter(term.dateValue!) ||
                taskDate.isAtSameMomentAs(term.dateValue!));
      case TaskQueryDateOp.on:
        if (taskDate == null || term.dateValue == null) return false;
        final localTask = taskDate.toLocal();
        final localTarget = term.dateValue!.toLocal();
        return localTask.year == localTarget.year &&
            localTask.month == localTarget.month &&
            localTask.day == localTarget.day;
    }
  }

  return true;
}

TaskStatus? _parseStatus(String raw) {
  final value = raw.toLowerCase();
  switch (value) {
    case 'done':
    case 'complete':
      return TaskStatus.completed;
    case 'pending':
      return TaskStatus.pending;
    case 'completed':
      return TaskStatus.completed;
    case 'deleted':
      return TaskStatus.deleted;
    case 'recurring':
      return TaskStatus.recurring;
  }

  for (final status in TaskStatus.values) {
    if (status.name == value) return status;
  }
  return null;
}

TaskQueryFlag? _parseFlag(String raw) {
  final value = raw.toLowerCase();
  switch (value) {
    case 'ready':
      return TaskQueryFlag.ready;
    case 'active':
      return TaskQueryFlag.active;
    case 'due':
      return TaskQueryFlag.due;
    case 'duetoday':
    case 'due.today':
    case 'today':
      return TaskQueryFlag.dueToday;
    case 'overdue':
      return TaskQueryFlag.overdue;
    case 'someday':
      return TaskQueryFlag.someday;
    case 'project':
      return TaskQueryFlag.project;
    case 'template':
      return TaskQueryFlag.template;
    case 'blocked':
      return TaskQueryFlag.blocked;
    case 'blocking':
      return TaskQueryFlag.blocking;
    case 'waiting':
    case 'wait':
      return TaskQueryFlag.waiting;
  }
  return null;
}

TaskQueryTerm? _parseDateTerm(String rawKey, String rawValue, DateTime nowUtc) {
  final dot = rawKey.indexOf('.');
  final key = _canonicalKey(dot == -1 ? rawKey : rawKey.substring(0, dot));
  final opName = dot == -1 ? 'on' : rawKey.substring(dot + 1);

  final field = _dateFieldFromKey(key);
  if (field == null) return null;

  final op = switch (opName) {
    'before' => TaskQueryDateOp.before,
    'beforeeq' => TaskQueryDateOp.beforeEq,
    'after' => TaskQueryDateOp.after,
    'aftereq' => TaskQueryDateOp.afterEq,
    'on' => TaskQueryDateOp.on,
    'none' => TaskQueryDateOp.none,
    'any' => TaskQueryDateOp.any,
    _ => TaskQueryDateOp.on,
  };

  if (op == TaskQueryDateOp.none || op == TaskQueryDateOp.any) {
    return TaskQueryTerm.date(field: field, op: op);
  }

  final value = _parseDateExpression(rawValue, nowUtc);
  if (value == null) {
    return null;
  }
  return TaskQueryTerm.date(field: field, op: op, value: value);
}

TaskQueryDateField? _dateFieldFromKey(String key) {
  return switch (key) {
    'due' => TaskQueryDateField.due,
    'wait' => TaskQueryDateField.wait,
    'scheduled' => TaskQueryDateField.scheduled,
    'entry' => TaskQueryDateField.entry,
    'modified' => TaskQueryDateField.modified,
    'start' => TaskQueryDateField.start,
    'end' => TaskQueryDateField.end,
    'until' => TaskQueryDateField.until,
    _ => null,
  };
}

DateTime? _readDateField(TaskView task, TaskQueryDateField field) {
  final raw = switch (field) {
    TaskQueryDateField.due => task.due,
    TaskQueryDateField.wait => task.wait,
    TaskQueryDateField.scheduled => task.scheduled,
    TaskQueryDateField.entry => task.entry,
    TaskQueryDateField.modified => task.modified,
    TaskQueryDateField.start => task.start,
    TaskQueryDateField.end => task.end,
    TaskQueryDateField.until => task.until,
  };
  if (raw == null || raw.isEmpty) return null;
  return DateTime.tryParse(raw)?.toUtc();
}

DateTime? _parseDateExpression(String raw, DateTime nowUtc) {
  final value = raw.toLowerCase();
  final localNow = nowUtc.toLocal();

  if (value == 'today') {
    return DateTime(localNow.year, localNow.month, localNow.day).toUtc();
  }
  if (value == 'tomorrow') {
    final day = localNow.add(const Duration(days: 1));
    return DateTime(day.year, day.month, day.day).toUtc();
  }
  if (value == 'yesterday') {
    final day = localNow.subtract(const Duration(days: 1));
    return DateTime(day.year, day.month, day.day).toUtc();
  }
  if (value == 'now') return nowUtc;
  if (value == 'sow') {
    final offset = localNow.weekday - DateTime.monday;
    final day = localNow.subtract(Duration(days: offset));
    return DateTime(day.year, day.month, day.day).toUtc();
  }
  if (value == 'eow') {
    final offset = DateTime.sunday - localNow.weekday;
    final day = localNow.add(Duration(days: offset));
    return DateTime(day.year, day.month, day.day, 23, 59, 59).toUtc();
  }
  if (value == 'som') {
    return DateTime(localNow.year, localNow.month, 1).toUtc();
  }
  if (value == 'eom') {
    final day = DateTime(localNow.year, localNow.month + 1, 0, 23, 59, 59);
    return day.toUtc();
  }
  if (value == 'soy') {
    return DateTime(localNow.year, 1, 1).toUtc();
  }
  if (value == 'eoy') {
    return DateTime(localNow.year, 12, 31, 23, 59, 59).toUtc();
  }

  final relative = RegExp(r'^([+-]?\d+)([dwmy])$').firstMatch(value);
  if (relative != null) {
    final amount = int.tryParse(relative.group(1) ?? '0') ?? 0;
    final unit = relative.group(2);
    final date = switch (unit) {
      'd' => localNow.add(Duration(days: amount)),
      'w' => localNow.add(Duration(days: amount * 7)),
      'm' => _addCalendarMonths(localNow, amount),
      'y' => _addCalendarYears(localNow, amount),
      _ => localNow,
    };
    return DateTime(date.year, date.month, date.day).toUtc();
  }

  return DateTime.tryParse(raw)?.toUtc();
}

DateTime _addCalendarMonths(DateTime source, int amount) {
  final targetMonth = source.month + amount;
  final maxDay = DateTime(source.year, targetMonth + 1, 0).day;
  final day = source.day > maxDay ? maxDay : source.day;
  return DateTime(source.year, targetMonth, day);
}

DateTime _addCalendarYears(DateTime source, int amount) {
  final targetYear = source.year + amount;
  final maxDay = DateTime(targetYear, source.month + 1, 0).day;
  final day = source.day > maxDay ? maxDay : source.day;
  return DateTime(targetYear, source.month, day);
}

List<String> _tokenizeQuery(String input) {
  final tokens = <String>[];
  final buffer = StringBuffer();
  String? quoteChar;

  void flush() {
    if (buffer.isEmpty) return;
    tokens.add(buffer.toString());
    buffer.clear();
  }

  for (var i = 0; i < input.length; i++) {
    final char = input[i];
    if (quoteChar != null) {
      if (char == quoteChar) {
        quoteChar = null;
      } else {
        buffer.write(char);
      }
      continue;
    }

    if (char == '"' || char == '\'') {
      quoteChar = char;
      continue;
    }
    if (char == '(' || char == ')') {
      flush();
      tokens.add(char);
      continue;
    }
    if (char == '&' && i + 1 < input.length && input[i + 1] == '&') {
      flush();
      tokens.add('&&');
      i++;
      continue;
    }
    if (char == '|' && i + 1 < input.length && input[i + 1] == '|') {
      flush();
      tokens.add('||');
      i++;
      continue;
    }
    if (_isWhitespace(char)) {
      flush();
      continue;
    }
    buffer.write(char);
  }
  flush();
  return tokens;
}

List<String> _mergeColonTokens(List<String> tokens) {
  final result = <String>[];
  var i = 0;
  while (i < tokens.length) {
    if (tokens[i].endsWith(':') && i + 1 < tokens.length) {
      final next = tokens[i + 1];
      const operators = {
        '(',
        ')',
        '&&',
        '||',
        'and',
        'AND',
        'or',
        'OR',
        'not',
        'NOT',
        '!',
      };
      if (!operators.contains(next)) {
        result.add('${tokens[i]}$next');
        i += 2;
        continue;
      }
    }
    result.add(tokens[i]);
    i++;
  }
  return result;
}

bool _isWhitespace(String char) {
  return char == ' ' || char == '\n' || char == '\t' || char == '\r';
}

String _stripQuotes(String input) {
  final trimmed = input.trim();
  if (trimmed.length < 2) return trimmed;
  final first = trimmed[0];
  final last = trimmed[trimmed.length - 1];
  if ((first == '"' && last == '"') || (first == '\'' && last == '\'')) {
    return trimmed.substring(1, trimmed.length - 1);
  }
  return trimmed;
}

bool _equalsIgnoreCase(String a, String b) =>
    a.toLowerCase() == b.toLowerCase();
