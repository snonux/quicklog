import 'package:shared_preferences/shared_preferences.dart';

import 's3_config.dart';
import 'storage.dart';

const _kDirectory = 'Directory';
const _kAutoLogSharedText = 'AutoLogSharedText';
const _kStorageMode = 'StorageMode';
const _kDegradedUntil = 'S3DegradedUntil';
const _kS3Endpoint = 'S3Endpoint';
const _kS3Region = 'S3Region';
const _kS3Bucket = 'S3Bucket';
const _kS3AccessKeyId = 'S3AccessKeyId';
const _kS3SecretAccessKey = 'S3SecretAccessKey';

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

  Future<S3Config> s3Config() async {
    final prefs = await SharedPreferences.getInstance();
    return S3Config(
      endpoint: prefs.getString(_kS3Endpoint)?.trim().isNotEmpty == true
          ? prefs.getString(_kS3Endpoint)!.trim()
          : kDefaultS3Endpoint,
      region: prefs.getString(_kS3Region)?.trim().isNotEmpty == true
          ? prefs.getString(_kS3Region)!.trim()
          : kDefaultS3Region,
      bucket: prefs.getString(_kS3Bucket)?.trim().isNotEmpty == true
          ? prefs.getString(_kS3Bucket)!.trim()
          : kDefaultS3Bucket,
      accessKeyId: prefs.getString(_kS3AccessKeyId) ?? '',
      secretAccessKey: prefs.getString(_kS3SecretAccessKey) ?? '',
    );
  }

  Future<void> setS3Config(S3Config config) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kS3Endpoint, config.endpoint.trim());
    await prefs.setString(_kS3Region, config.region.trim());
    await prefs.setString(_kS3Bucket, config.bucket.trim());
    await prefs.setString(_kS3AccessKeyId, config.accessKeyId);
    await prefs.setString(_kS3SecretAccessKey, config.secretAccessKey);
  }
}
