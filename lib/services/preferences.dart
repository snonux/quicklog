import 'package:shared_preferences/shared_preferences.dart';

import 'storage.dart';

const _kDirectory = 'Directory';
const _kAutoLogSharedText = 'AutoLogSharedText';
const _kStorageMode = 'StorageMode';
const _kDegradedUntil = 'S3DegradedUntil';

/// Where new notes are written. Default is [local] — on-device files only.
enum StorageMode {
  local,
  s3;

  static StorageMode parse(String? raw) {
    switch (raw) {
      case 's3':
        return StorageMode.s3;
      case 'local':
      default:
        return StorageMode.local;
    }
  }

  String get wireName => name;
}

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

  Future<StorageMode> storageMode() async {
    final prefs = await SharedPreferences.getInstance();
    return StorageMode.parse(prefs.getString(_kStorageMode));
  }

  /// End of the S3 degrade window, or null when not degraded.
  Future<DateTime?> degradedUntil() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kDegradedUntil);
    if (raw == null || raw.isEmpty) return null;
    return DateTime.tryParse(raw);
  }

  Future<void> setDirectory(String value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kDirectory, value);
  }

  Future<void> setAutoLogSharedText(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kAutoLogSharedText, value);
  }

  Future<void> setStorageMode(StorageMode mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kStorageMode, mode.wireName);
  }

  Future<void> setDegradedUntil(DateTime? until) async {
    final prefs = await SharedPreferences.getInstance();
    if (until == null) {
      await prefs.remove(_kDegradedUntil);
    } else {
      await prefs.setString(_kDegradedUntil, until.toUtc().toIso8601String());
    }
  }
}
