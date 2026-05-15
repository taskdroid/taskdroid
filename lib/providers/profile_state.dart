import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:taskdroid/models/profile.dart';
import 'package:taskdroid/services/credentials_storage.dart';
import 'package:taskdroid/services/profile_storage.dart';
import 'package:taskdroid/src/rust/api.dart';

class ProfileState extends ChangeNotifier {
  List<Profile> _profiles = [];
  String? _currentProfileId;

  bool _isLoaded = false;
  bool get isLoaded => _isLoaded;

  List<Profile> get profiles => _profiles;
  String? get currentProfileId => _currentProfileId;

  Profile? get currentProfile {
    if (_currentProfileId == null) return null;
    try {
      return _profiles.firstWhere((p) => p.id == _currentProfileId);
    } catch (_) {
      return null;
    }
  }

  ProfileState() {
    _loadProfiles();
  }

  Future<void> _loadProfiles() async {
    _profiles = await CredentialsStorage.loadProfiles();
    _currentProfileId = await CredentialsStorage.loadCurrentProfileId();
    _isLoaded = true;
    notifyListeners();

    if (_profiles.isNotEmpty) {
      await migrateLegacyProfileDirectories(_profiles);
    }
  }

  Future<void> addProfile(Profile profile) async {
    _profiles.add(profile);
    await CredentialsStorage.saveProfiles(_profiles);
    await _ensureProfileDatabase(profile);
    notifyListeners();
  }

  Future<bool> updateProfile(Profile updatedProfile) async {
    final index = _profiles.indexWhere((p) => p.id == updatedProfile.id);
    if (index == -1) return false;

    final oldProfile = _profiles[index];
    var canProceed = true;
    if (oldProfile.name != updatedProfile.name) {
      canProceed = await renameProfileDirectory(oldProfile, updatedProfile);
    }
    if (!canProceed) return false;

    _profiles[index] = updatedProfile;
    await CredentialsStorage.saveProfiles(_profiles);
    await _ensureProfileDatabase(updatedProfile);
    notifyListeners();
    return true;
  }

  Future<void> setCalendarSyncForCurrentProfile(bool enabled) async {
    final profile = currentProfile;
    if (profile != null) {
      final updated = profile.copyWith(calendarSync: enabled);
      await updateProfile(updated);
    }
  }

  Future<void> setRecurrenceLimitForCurrentProfile(int limit) async {
    final profile = currentProfile;
    if (profile != null) {
      final normalized = limit < 0 ? 0 : limit;
      final updated = profile.copyWith(recurrenceLimit: normalized);
      await updateProfile(updated);
    }
  }

  Future<void> deleteProfile(String profileId) async {
    await _deleteProfileDatabase(profileId);

    _profiles.removeWhere((p) => p.id == profileId);
    if (_currentProfileId == profileId) {
      _currentProfileId = null;
      await CredentialsStorage.saveCurrentProfileId(null);
    }
    await CredentialsStorage.saveProfiles(_profiles);

    // Clean up persisted filter tabs for this profile
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('filter_tabs_$profileId');
      await prefs.remove('current_tab_id_$profileId');
    } catch (e) {
      debugPrint('Failed to clean up filter tabs for $profileId: $e');
    }

    notifyListeners();
  }

  Future<void> _deleteProfileDatabase(String profileId) async {
    try {
      final profile = _profiles.firstWhere(
        (p) => p.id == profileId,
        orElse: () => Profile(
          id: profileId,
          name: profileId,
          uuid: '',
          secret: '',
          serverUrl: '',
        ),
      );
      final basePath = await getGlobalStoragePath();
      final dbDir = await resolveProfileStorageDir(profile);
      if (await dbDir.exists()) {
        await dbDir.delete(recursive: true);
      }
      final legacyDir = Directory('$basePath/${profile.id}/');
      if (await legacyDir.exists()) {
        await legacyDir.delete(recursive: true);
      }
    } catch (e) {
      debugPrint('Failed to delete TaskChampion DB for $profileId: $e');
    }
  }

  Future<void> setCurrentProfile(String? profileId) async {
    _currentProfileId = profileId;
    await CredentialsStorage.saveCurrentProfileId(profileId);
    notifyListeners();
  }

  Future<void> _ensureProfileDatabase(Profile profile) async {
    try {
      final dbDir = await resolveProfileStorageDir(profile);
      await dbDir.create(recursive: true);

      final manager = TaskManager();
      await manager.loadProfile(directoryPath: dbDir.path);
    } catch (e) {
      debugPrint('Failed to initialize TaskChampion DB for ${profile.id}: $e');
    }
  }
}
