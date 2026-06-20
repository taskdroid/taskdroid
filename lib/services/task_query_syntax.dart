class TaskQuerySyntax {
  const TaskQuerySyntax._();

  static const List<String> logicalOperators = ['and', 'or', 'not', 'xor'];

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
    'priority',
    'until',
    'instance',
    'latest',
    'tagged',
    'unblocked',
    'annotated',
    'scheduled',
    'tomorrow',
    'yesterday',
    'week',
    'month',
    'quarter',
    'year',
    'uda',
    'orphan',
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
    'under',
    'below',
    'beforeeq',
    'by',
    'after',
    'over',
    'above',
    'aftereq',
    'on',
    'none',
    'any',
  ];

  static const Map<String, String> statusAliases = {
    'done': 'completed',
    'complete': 'completed',
  };

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

  static const List<String> attributeModifierNames = [
    'has',
    'hasnt',
    'startswith',
    'endswith',
    'contains',
    'isnt',
    'not',
  ];

  static const List<String> comparisonOperatorNames = [
    '==',
    '!=',
    '!==',
    '=',
    '>',
    '<',
    '>=',
    '<=',
  ];

  static String canonicalKey(String key) => fieldAliases[key] ?? key;
}
