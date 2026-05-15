import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:taskdroid/models/profile.dart';

class CredentialsStorage {
  static const _keyProfiles = 'taskwarrior_profiles';
  static const _keyCurrentProfileId = 'taskwarrior_current_profile_id';

  static const FlutterSecureStorage _storage = FlutterSecureStorage();

  static Future<void> saveProfiles(List<Profile> profiles) async {
    final profilesJson = profiles.map((p) => p.toJson()).toList();
    final jsonString = jsonEncode(profilesJson);
    await _storage.write(key: _keyProfiles, value: jsonString);
  }

  static Future<List<Profile>> loadProfiles() async {
    final jsonString = await _storage.read(key: _keyProfiles);
    if (jsonString == null || jsonString.isEmpty) {
      return [];
    }
    try {
      final List<dynamic> profilesJson = jsonDecode(jsonString);
      return profilesJson
          .map((json) => Profile.fromJson(json as Map<String, dynamic>))
          .toList();
    } catch (e) {
      return [];
    }
  }

  static Future<void> saveCurrentProfileId(String? profileId) async {
    if (profileId == null) {
      await _storage.delete(key: _keyCurrentProfileId);
    } else {
      await _storage.write(key: _keyCurrentProfileId, value: profileId);
    }
  }

  static Future<String?> loadCurrentProfileId() async {
    return await _storage.read(key: _keyCurrentProfileId);
  }

  static Future<Profile?> getCurrentProfile() async {
    final profileId = await loadCurrentProfileId();
    if (profileId == null) return null;
    final profiles = await loadProfiles();
    try {
      return profiles.firstWhere((p) => p.id == profileId);
    } catch (e) {
      return null;
    }
  }
}
