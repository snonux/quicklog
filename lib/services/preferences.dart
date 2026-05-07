import 'package:shared_preferences/shared_preferences.dart';

import 'storage.dart';

const _kDirectory = 'Directory';
const _kAutoLogSharedText = 'AutoLogSharedText';

class PreferencesService {
  Future<String> directory() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString(_kDirectory);
    if (stored != null && stored.isNotEmpty) return stored;
    return defaultLogDirectory();
  }

  Future<bool> autoLogSharedText() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_kAutoLogSharedText) ?? false;
  }

  Future<void> setDirectory(String value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kDirectory, value);
  }

  Future<void> setAutoLogSharedText(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kAutoLogSharedText, value);
  }
}
