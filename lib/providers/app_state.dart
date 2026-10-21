import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum SwipeAction { none, markDone, delete }

class AppState extends ChangeNotifier {
  static const String _keyDarkTheme = 'dark_theme_enabled';
  static const String _keySyncOnStart = 'sync_on_start';
  static const String _keyLeftSwipe = 'left_swipe_action';
  static const String _keyRightSwipe = 'right_swipe_action';
  static const String trustUserCertsKey = 'trust_user_certs';

  bool _isDarkTheme = false;
  bool get isDarkTheme => _isDarkTheme;

  bool _syncOnStart = false;
  bool get syncOnStart => _syncOnStart;

  bool _trustUserCerts = false;
  bool get trustUserCerts => _trustUserCerts;

  bool _isLoaded = false;
  bool get isLoaded => _isLoaded;

  SwipeAction _leftSwipeAction = SwipeAction.markDone;
  SwipeAction get leftSwipeAction => _leftSwipeAction;

  SwipeAction _rightSwipeAction = SwipeAction.delete;
  SwipeAction get rightSwipeAction => _rightSwipeAction;

  AppState() {
    _loadPreferences();
  }

  Future<void> _loadPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    _isDarkTheme = prefs.getBool(_keyDarkTheme) ?? false;
    _syncOnStart = prefs.getBool(_keySyncOnStart) ?? false;
    _trustUserCerts = prefs.getBool(trustUserCertsKey) ?? false;

    final leftSwipeIdx =
        prefs.getInt(_keyLeftSwipe) ?? SwipeAction.markDone.index;
    _leftSwipeAction =
        (leftSwipeIdx >= 0 && leftSwipeIdx < SwipeAction.values.length)
        ? SwipeAction.values[leftSwipeIdx]
        : SwipeAction.markDone;

    final rightSwipeIdx =
        prefs.getInt(_keyRightSwipe) ?? SwipeAction.delete.index;
    _rightSwipeAction =
        (rightSwipeIdx >= 0 && rightSwipeIdx < SwipeAction.values.length)
        ? SwipeAction.values[rightSwipeIdx]
        : SwipeAction.delete;

    _isLoaded = true;
    notifyListeners();
  }

  Future<void> setDarkTheme(bool value) async {
    _isDarkTheme = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyDarkTheme, value);
  }

  Future<void> setSyncOnStart(bool value) async {
    _syncOnStart = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keySyncOnStart, value);
  }

  Future<void> setTrustUserCerts(bool value) async {
    _trustUserCerts = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(trustUserCertsKey, value);
  }

  Future<void> setLeftSwipeAction(SwipeAction action) async {
    _leftSwipeAction = action;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_keyLeftSwipe, action.index);
  }

  Future<void> setRightSwipeAction(SwipeAction action) async {
    _rightSwipeAction = action;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_keyRightSwipe, action.index);
  }
}
