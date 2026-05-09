enum FilterMatchMode { and, or }

enum TaskVirtualFlag {
  ready,
  active,
  due,
  dueToday,
  overdue,
  someday,
  project,
  template,
}

class FilterTab {
  final String id;
  final String name;
  final String searchQuery;
  final Set<String> selectedTags;
  final Set<String> selectedProjects;
  final Set<String>? includeTags;
  final Set<String>? excludeTags;
  final FilterMatchMode? tagMatchMode;
  final Set<String>? includeProjects;
  final Set<String>? excludeProjects;
  final FilterMatchMode? projectMatchMode;
  final Set<String>? includeStatuses;
  final Set<String>? excludeStatuses;
  final Set<String>? includeFlags;
  final Set<String>? excludeFlags;
  final FilterMatchMode? flagMatchMode;

  FilterTab({
    required this.id,
    required this.name,
    this.searchQuery = '',
    Set<String>? selectedTags,
    Set<String>? selectedProjects,
    this.includeTags,
    this.excludeTags,
    this.tagMatchMode,
    this.includeProjects,
    this.excludeProjects,
    this.projectMatchMode,
    this.includeStatuses,
    this.excludeStatuses,
    this.includeFlags,
    this.excludeFlags,
    this.flagMatchMode,
  }) : selectedTags = selectedTags ?? {},
       selectedProjects = selectedProjects ?? {};

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'searchQuery': searchQuery,
      'selectedTags': selectedTags.toList(),
      'selectedProjects': selectedProjects.toList(),
      'includeTags': includeTags?.toList(),
      'excludeTags': excludeTags?.toList(),
      'tagMatchMode': tagMatchMode?.name,
      'includeProjects': includeProjects?.toList(),
      'excludeProjects': excludeProjects?.toList(),
      'projectMatchMode': projectMatchMode?.name,
      'includeStatuses': includeStatuses?.toList(),
      'excludeStatuses': excludeStatuses?.toList(),
      'includeFlags': includeFlags?.toList(),
      'excludeFlags': excludeFlags?.toList(),
      'flagMatchMode': flagMatchMode?.name,
    };
  }

  factory FilterTab.fromJson(Map<String, dynamic> json) {
    return FilterTab(
      id: json['id'] as String,
      name: json['name'] as String,
      searchQuery: json['searchQuery'] as String? ?? '',
      selectedTags:
          (json['selectedTags'] as List<dynamic>?)
              ?.map((e) => e as String)
              .toSet() ??
          {},
      selectedProjects:
          (json['selectedProjects'] as List<dynamic>?)
              ?.map((e) => e as String)
              .toSet() ??
          {},
      includeTags: (json['includeTags'] as List<dynamic>?)
          ?.map((e) => e as String)
          .toSet(),
      excludeTags: (json['excludeTags'] as List<dynamic>?)
          ?.map((e) => e as String)
          .toSet(),
      tagMatchMode: _matchModeFromJson(json['tagMatchMode']),
      includeProjects: (json['includeProjects'] as List<dynamic>?)
          ?.map((e) => e as String)
          .toSet(),
      excludeProjects: (json['excludeProjects'] as List<dynamic>?)
          ?.map((e) => e as String)
          .toSet(),
      projectMatchMode: _matchModeFromJson(json['projectMatchMode']),
      includeStatuses: (json['includeStatuses'] as List<dynamic>?)
          ?.map((e) => e as String)
          .toSet(),
      excludeStatuses: (json['excludeStatuses'] as List<dynamic>?)
          ?.map((e) => e as String)
          .toSet(),
      includeFlags: (json['includeFlags'] as List<dynamic>?)
          ?.map((e) => e as String)
          .toSet(),
      excludeFlags: (json['excludeFlags'] as List<dynamic>?)
          ?.map((e) => e as String)
          .toSet(),
      flagMatchMode: _matchModeFromJson(json['flagMatchMode']),
    );
  }

  FilterTab copyWith({
    String? id,
    String? name,
    String? searchQuery,
    Set<String>? selectedTags,
    Set<String>? selectedProjects,
    Set<String>? includeTags,
    Set<String>? excludeTags,
    FilterMatchMode? tagMatchMode,
    Set<String>? includeProjects,
    Set<String>? excludeProjects,
    FilterMatchMode? projectMatchMode,
    Set<String>? includeStatuses,
    Set<String>? excludeStatuses,
    Set<String>? includeFlags,
    Set<String>? excludeFlags,
    FilterMatchMode? flagMatchMode,
  }) {
    return FilterTab(
      id: id ?? this.id,
      name: name ?? this.name,
      searchQuery: searchQuery ?? this.searchQuery,
      selectedTags: selectedTags ?? this.selectedTags,
      selectedProjects: selectedProjects ?? this.selectedProjects,
      includeTags: includeTags ?? this.includeTags,
      excludeTags: excludeTags ?? this.excludeTags,
      tagMatchMode: tagMatchMode ?? this.tagMatchMode,
      includeProjects: includeProjects ?? this.includeProjects,
      excludeProjects: excludeProjects ?? this.excludeProjects,
      projectMatchMode: projectMatchMode ?? this.projectMatchMode,
      includeStatuses: includeStatuses ?? this.includeStatuses,
      excludeStatuses: excludeStatuses ?? this.excludeStatuses,
      includeFlags: includeFlags ?? this.includeFlags,
      excludeFlags: excludeFlags ?? this.excludeFlags,
      flagMatchMode: flagMatchMode ?? this.flagMatchMode,
    );
  }
}

FilterMatchMode? _matchModeFromJson(dynamic raw) {
  if (raw is! String) return null;
  for (final mode in FilterMatchMode.values) {
    if (mode.name == raw) return mode;
  }
  return null;
}
