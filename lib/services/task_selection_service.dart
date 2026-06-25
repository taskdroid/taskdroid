class TaskSelectionService {
  final Set<String> _selectedTaskUuids = {};

  Set<String> get selectedUuids => Set.unmodifiable(_selectedTaskUuids);
  bool get isEmpty => _selectedTaskUuids.isEmpty;
  bool get isNotEmpty => _selectedTaskUuids.isNotEmpty;

  bool contains(String uuid) => _selectedTaskUuids.contains(uuid);

  void toggle(String uuid) {
    if (_selectedTaskUuids.contains(uuid)) {
      _selectedTaskUuids.remove(uuid);
    } else {
      _selectedTaskUuids.add(uuid);
    }
  }

  void clear() {
    _selectedTaskUuids.clear();
  }
}
