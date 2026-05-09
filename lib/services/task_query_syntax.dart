class TaskQuerySyntax {
  const TaskQuerySyntax._();

  static const List<String> logicalOperators = ['and', 'or', 'not'];

  static const Map<String, String> fieldAliases = {
    'pro': 'project',
    'proj': 'project',
    'pri': 'priority',
    'stat': 'status',
    'id': 'uuid',
  };

  static const List<String> fieldNames = [
    'project',
    'tag',
    'tags',
    'status',
    'priority',
    'uuid',
    'description',
    'desc',
    'due',
    'wait',
    'scheduled',
    'entry',
    'modified',
    'start',
    'end',
    'until',
  ];

  static const List<String> statusNames = [
    'pending',
    'completed',
    'deleted',
    'recurring',
    'done',
    'complete',
  ];

  static const List<String> flagNames = [
    'ready',
    'active',
    'due',
    'duetoday',
    'due.today',
    'today',
    'overdue',
    'someday',
    'project',
    'template',
    'blocked',
    'blocking',
    'waiting',
    'wait',
  ];

  static const List<String> dateFieldNames = [
    'due',
    'wait',
    'scheduled',
    'entry',
    'modified',
    'start',
    'end',
    'until',
  ];

  static const List<String> dateOperatorNames = [
    'before',
    'beforeeq',
    'after',
    'aftereq',
    'on',
    'none',
    'any',
  ];

  static const List<String> dateLiteralNames = [
    'today',
    'tomorrow',
    'yesterday',
    'now',
    'sow',
    'eow',
    'som',
    'eom',
    'soy',
    'eoy',
  ];

  static String canonicalKey(String key) => fieldAliases[key] ?? key;
}
