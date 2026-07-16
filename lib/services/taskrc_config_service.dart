import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:taskdroid/models/profile.dart';
import 'package:taskdroid/services/profile_storage.dart';
import 'package:taskdroid/src/rust/api.dart';

class TaskrcConfigService {
  final TaskManager _manager;

  TaskrcConfigService(this._manager);

  Future<Map<String, String>> getAllConfig() async {
    final pairs = await _manager.getAllConfig();
    return {for (final p in pairs) p.key: p.value};
  }

  Future<String?> getConfigValue(String key) async {
    return _manager.getConfigValue(key: key);
  }

  Future<void> setConfigValue(String key, String value) async {
    await _manager.setConfigValue(key: key, value: value);
  }

  Future<List<ConfigIssue>> validateTaskrc(String content) async {
    return _manager.validateTaskrc(content: content);
  }

  static Future<String> resolveTaskrcPath(Profile profile) async {
    final dir = await resolveProfileStorageDir(profile);
    return '${dir.path}/taskrc';
  }

  static Future<String?> readRawContent(Profile profile) async {
    try {
      final path = await resolveTaskrcPath(profile);
      final file = File(path);
      if (await file.exists()) {
        return await file.readAsString();
      }
      return null;
    } catch (e) {
      debugPrint('Failed to read taskrc: $e');
      return null;
    }
  }

  static Future<bool> writeRawContent(Profile profile, String content) async {
    try {
      final path = await resolveTaskrcPath(profile);
      final file = File(path);
      await file.parent.create(recursive: true);
      await file.writeAsString(content);
      return true;
    } catch (e) {
      debugPrint('Failed to write taskrc: $e');
      return false;
    }
  }

  static Future<bool> exists(Profile profile) async {
    try {
      final path = await resolveTaskrcPath(profile);
      return await File(path).exists();
    } catch (e) {
      return false;
    }
  }
}
