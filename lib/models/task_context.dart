class TaskContext {
  final String id;
  final String name;
  final String searchQuery;
  final String writeQuery;

  TaskContext({
    required this.id,
    required this.name,
    this.searchQuery = '',
    this.writeQuery = '',
  });

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'searchQuery': searchQuery,
      'writeQuery': writeQuery,
    };
  }

  factory TaskContext.fromJson(Map<String, dynamic> json) {
    return TaskContext(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      searchQuery: json['searchQuery'] as String? ?? '',
      writeQuery: json['writeQuery'] as String? ?? '',
    );
  }

  TaskContext copyWith({
    String? id,
    String? name,
    String? searchQuery,
    String? writeQuery,
  }) {
    return TaskContext(
      id: id ?? this.id,
      name: name ?? this.name,
      searchQuery: searchQuery ?? this.searchQuery,
      writeQuery: writeQuery ?? this.writeQuery,
    );
  }
}
