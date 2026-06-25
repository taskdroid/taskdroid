import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:taskdroid/models/filter_tab.dart';
import 'package:taskdroid/services/task_filter_service.dart';
import 'package:taskdroid/src/rust/api.dart';
import 'package:uuid/uuid.dart';

class TaskTabService {
  List<FilterTab> _filterTabs = [];
  String? _currentTabId;
  Timer? _saveTabTimer;

  // --- getters
  List<FilterTab> get filterTabs => _filterTabs;
  String? get currentTabId => _currentTabId;

  FilterTab? currentTab() {
    if (_currentTabId == null) return null;
    try {
      return _filterTabs.firstWhere((tab) => tab.id == _currentTabId);
    } catch (_) {
      return null;
    }
  }

  // --- persistence
  Future<void> loadTabs(
    String profileId,
    TaskFilterService filterService,
  ) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonString = prefs.getString('filter_tabs_$profileId');

      if (jsonString != null && jsonString.isNotEmpty) {
        final List<dynamic> tabsJson = jsonDecode(jsonString);
        _filterTabs = tabsJson.map((j) => FilterTab.fromJson(j)).toList();
        _currentTabId = prefs.getString('current_tab_id_$profileId');

        final tab = currentTab();
        if (tab != null) {
          applyTab(tab, filterService);
        }
      } else {
        final defaultTab = FilterTab(id: const Uuid().v4(), name: 'All Tasks');
        _filterTabs = [defaultTab];
        _currentTabId = defaultTab.id;
        applyTab(defaultTab, filterService);
        await saveTabs(profileId);
      }
    } catch (e) {
      debugPrint('Tab load error: $e');
    }
  }

  Future<void> saveTabs(String profileId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'filter_tabs_$profileId',
      jsonEncode(_filterTabs.map((t) => t.toJson()).toList()),
    );
    if (_currentTabId != null) {
      await prefs.setString('current_tab_id_$profileId', _currentTabId!);
    }
  }

  // --- CRUD
  Future<void> switchToTab(
    String tabId,
    TaskFilterService filterService,
  ) async {
    _saveTabTimer?.cancel();
    await persistCurrentSettings(filterService);
    _currentTabId = tabId;
    final tab = currentTab();
    if (tab != null) {
      applyTab(tab, filterService);
    }
  }

  Future<void> addTab(String name, TaskFilterService filterService) async {
    final newTab = FilterTab(
      id: const Uuid().v4(),
      name: name,
      searchQuery: filterService.searchQuery,
      selectedTags: const <String>{},
      selectedProjects: const <String>{},
      includeTags: filterService.includeTags.isEmpty
          ? null
          : Set.from(filterService.includeTags),
      excludeTags: filterService.excludeTags.isEmpty
          ? null
          : Set.from(filterService.excludeTags),
      tagMatchMode: filterService.tagMatchMode,
      includeProjects: filterService.includeProjects.isEmpty
          ? null
          : Set.from(filterService.includeProjects),
      excludeProjects: filterService.excludeProjects.isEmpty
          ? null
          : Set.from(filterService.excludeProjects),
      projectMatchMode: filterService.projectMatchMode,
    );
    _filterTabs = [..._filterTabs, newTab];
    _currentTabId = newTab.id;
  }

  Future<void> deleteTab(String id, TaskFilterService filterService) async {
    if (_filterTabs.length <= 1) return;
    _filterTabs = _filterTabs.where((t) => t.id != id).toList();
    if (_currentTabId == id) {
      await switchToTab(_filterTabs.first.id, filterService);
    }
  }

  Future<void> renameTab(String id, String name) async {
    final idx = _filterTabs.indexWhere((t) => t.id == id);
    if (idx != -1) {
      final newList = List<FilterTab>.from(_filterTabs);
      newList[idx] = newList[idx].copyWith(name: name);
      _filterTabs = newList;
    }
  }

  // --- debounced save
  void scheduleSave(String? profileId, TaskFilterService filterService) {
    _saveTabTimer?.cancel();
    _saveTabTimer = Timer(
      const Duration(milliseconds: 500),
      () => unawaited(_doSave(profileId, filterService)),
    );
  }

  Future<void> _doSave(
    String? profileId,
    TaskFilterService filterService,
  ) async {
    if (profileId == null || _currentTabId == null) return;
    await persistCurrentSettings(filterService);
    await saveTabs(profileId);
  }

  Future<void> persistCurrentSettings(TaskFilterService filterService) async {
    if (_currentTabId == null) return;
    final idx = _filterTabs.indexWhere((t) => t.id == _currentTabId);
    if (idx != -1) {
      final newList = List<FilterTab>.from(_filterTabs);
      final current = newList[idx];
      newList[idx] = FilterTab(
        id: current.id,
        name: current.name,
        searchQuery: filterService.searchQuery,
        selectedTags: const <String>{},
        selectedProjects: const <String>{},
        includeTags: filterService.includeTags,
        excludeTags: filterService.excludeTags,
        tagMatchMode: filterService.tagMatchMode,
        includeProjects: filterService.includeProjects,
        excludeProjects: filterService.excludeProjects,
        projectMatchMode: filterService.projectMatchMode,
      );
      _filterTabs = newList;
    }
  }

  // --- apply tab to filter state
  void applyTab(FilterTab tab, TaskFilterService filterService) {
    filterService.setSearchQuery(migratedSearchQuery(tab));
    filterService.setTagFilters(
      include: tab.includeTags == null
          ? Set.from(tab.selectedTags)
          : Set.from(tab.includeTags!),
      exclude: tab.excludeTags == null
          ? <String>{}
          : Set.from(tab.excludeTags!),
      mode: tab.tagMatchMode ?? FilterMatchMode.and,
    );
    filterService.setProjectFilters(
      include: tab.includeProjects == null
          ? Set.from(tab.selectedProjects)
          : Set.from(tab.includeProjects!),
      exclude: tab.excludeProjects == null
          ? <String>{}
          : Set.from(tab.excludeProjects!),
      mode: tab.projectMatchMode ?? FilterMatchMode.and,
    );
  }

  // --- legacy migration helpers
  String migratedSearchQuery(FilterTab tab) {
    final fragments = <String>[];
    final search = tab.searchQuery.trim();
    if (search.isNotEmpty) fragments.add(search);

    final includeStatuses = decodeStatuses(tab.includeStatuses) ?? {};
    final includeStatusFragments = includeStatuses
        .map((status) => 'status:${status.name}')
        .toList();
    if (includeStatusFragments.length > 1) {
      fragments.add('(${includeStatusFragments.join(' or ')})');
    } else {
      fragments.addAll(includeStatusFragments);
    }

    final excludeStatuses = decodeStatuses(tab.excludeStatuses) ?? {};
    fragments.addAll(excludeStatuses.map((status) => '-status:${status.name}'));

    final includeFlags = decodeFlags(tab.includeFlags) ?? {};
    final includeFlagFragments = includeFlags
        .map((flag) => '+${flagQueryToken(flag)}')
        .toList();
    if (includeFlagFragments.length > 1 &&
        tab.flagMatchMode == FilterMatchMode.or) {
      fragments.add('(${includeFlagFragments.join(' or ')})');
    } else {
      fragments.addAll(includeFlagFragments);
    }

    final excludeFlags = decodeFlags(tab.excludeFlags) ?? {};
    fragments.addAll(excludeFlags.map((flag) => '-${flagQueryToken(flag)}'));

    return fragments.join(' ');
  }

  String flagQueryToken(TaskVirtualFlag flag) => flag.name.toLowerCase();

  Set<TaskStatus>? decodeStatuses(Set<String>? raw) {
    if (raw == null) return null;
    final parsed = <TaskStatus>{};
    for (final value in raw) {
      for (final status in TaskStatus.values) {
        if (status.name == value) {
          parsed.add(status);
          break;
        }
      }
    }
    return parsed;
  }

  Set<TaskVirtualFlag>? decodeFlags(Set<String>? raw) {
    if (raw == null) return null;
    final parsed = <TaskVirtualFlag>{};
    for (final value in raw) {
      for (final flag in TaskVirtualFlag.values) {
        if (flag.name == value) {
          parsed.add(flag);
          break;
        }
      }
    }
    return parsed;
  }

  // --- lifecycle
  void dispose() {
    _saveTabTimer?.cancel();
  }

  void clear() {
    _filterTabs = [];
    _currentTabId = null;
  }
}
