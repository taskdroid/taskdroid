import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:taskdroid/models/task_context.dart';
import 'package:uuid/uuid.dart';

class TaskContextService {
  List<TaskContext> _contexts = [];
  String? _activeContextId;

  // --- getters
  List<TaskContext> get contexts => _contexts;
  String? get activeContextId => _activeContextId;

  TaskContext? get activeContext {
    if (_activeContextId == null) return null;
    try {
      return _contexts.firstWhere((c) => c.id == _activeContextId);
    } catch (_) {
      return null;
    }
  }

  // --- persistence
  Future<void> loadContexts(String profileId) async {
    _contexts = [];
    _activeContextId = null;
    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonString = prefs.getString('contexts_$profileId');
      if (jsonString != null && jsonString.isNotEmpty) {
        final List<dynamic> contextsJson = jsonDecode(jsonString);
        _contexts = contextsJson.map((j) => TaskContext.fromJson(j)).toList();
        final activeId = prefs.getString('active_context_id_$profileId');
        _activeContextId = activeId;
      }
    } catch (e) {
      debugPrint('Context load error: $e');
    }
  }

  Future<void> saveContexts(String profileId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'contexts_$profileId',
      jsonEncode(_contexts.map((c) => c.toJson()).toList()),
    );
    if (_activeContextId != null) {
      await prefs.setString('active_context_id_$profileId', _activeContextId!);
    } else {
      await prefs.remove('active_context_id_$profileId');
    }
  }

  // --- CRUD
  void defineContext(String name, String query, {String writeQuery = ''}) {
    final context = TaskContext(
      id: const Uuid().v4(),
      name: name,
      searchQuery: query,
      writeQuery: writeQuery,
    );
    _contexts = [..._contexts, context];
  }

  void deleteContext(String id) {
    _contexts = _contexts.where((c) => c.id != id).toList();
    if (_activeContextId == id) {
      _activeContextId = null;
    }
  }

  void setActiveContext(String? id) {
    if (id != null && !_contexts.any((c) => c.id == id)) return;
    _activeContextId = id;
  }

  void updateContext(
    String id,
    String name,
    String query, {
    String writeQuery = '',
  }) {
    final idx = _contexts.indexWhere((c) => c.id == id);
    if (idx != -1) {
      final newList = List<TaskContext>.from(_contexts);
      newList[idx] = newList[idx].copyWith(
        name: name,
        searchQuery: query,
        writeQuery: writeQuery,
      );
      _contexts = newList;
    }
  }

  void clear() {
    _contexts = [];
    _activeContextId = null;
  }
}
