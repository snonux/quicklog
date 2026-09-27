import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 's3_config.dart';
import 'storage.dart';

const _kDirectory = 'Directory';
const _kAutoLogSharedText = 'AutoLogSharedText';
const _kStorageMode = 'StorageMode';
const _kDegradedUntil = 'S3DegradedUntil';
const _kPendingUploads = 'DualWritePendingUploads';
const _kPendingDeletes = 'DualWritePendingDeletes';
const _kPending = 'DualWritePending';
const _kS3Endpoint = 'S3Endpoint';
const _kS3Region = 'S3Region';
const _kS3Bucket = 'S3Bucket';
const _kS3AccessKeyId = 'S3AccessKeyId';
const _kS3SecretAccessKey = 'S3SecretAccessKey';

/// Where new notes are written. Default is [local] — on-device files only.
enum StorageMode {
  local,
  s3,

  /// Dual write: every note goes to the local directory *and* S3.
  both;

  static StorageMode parse(String? raw) {
    switch (raw) {
      case 's3':
        return StorageMode.s3;
      case 'both':
        return StorageMode.both;
      case 'local':
      default:
        return StorageMode.local;
    }
  }

  /// True when S3 is part of the write target ([s3] or dual [both]).
  bool get writesToS3 => this == StorageMode.s3 || this == StorageMode.both;

  String get wireName => name;
}

class PreferencesService {
  Future<String> directory() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString(_kDirectory);
    if (stored != null && stored.isNotEmpty) return stored;
    return defaultLogDirectory();
  }

  /// The directory exactly as stored, or null when the user never picked one
  /// (so the platform default from [defaultLogDirectory] applies).
  ///
  /// Settings export uses this rather than [directory]: the default is an
  /// app-specific path that is resolved per install, so it must stay "default"
  /// on restore instead of being pinned to the old install's resolved path.
  Future<String?> storedDirectory() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString(_kDirectory);
    if (stored == null || stored.isEmpty) return null;
    return stored;
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

  /// Forget the chosen directory so [directory] falls back to the default.
  Future<void> clearDirectory() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kDirectory);
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

  /// Dual-write note ids whose local text still needs to overwrite S3.
  /// Transient, like [degradedUntil]: not part of a settings export.
  Future<List<String>> dualWritePendingUploads() async {
    return (await dualWritePending()).uploads;
  }

  /// Dual-write note ids removed on device whose S3 object is still there.
  Future<List<String>> dualWritePendingDeletes() async {
    return (await dualWritePending()).deletes;
  }

  /// Both repair lists and the notes directory they were queued for.
  ///
  /// One preference value, so a crash cannot save the upload list without
  /// the delete list. [directory] is the folder those ids belong to.
  Future<
    ({List<String> uploads, List<String> deletes, String? directory})
  >
  dualWritePending() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kPending);
    if (raw != null) return _decodePending(raw);
    return (
      uploads: List<String>.from(
        prefs.getStringList(_kPendingUploads) ?? const <String>[],
      ),
      deletes: List<String>.from(
        prefs.getStringList(_kPendingDeletes) ?? const <String>[],
      ),
      directory: null,
    );
  }

  Future<void> setDualWritePending({
    required List<String> uploads,
    required List<String> deletes,
    String? directory,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    if (uploads.isEmpty && deletes.isEmpty) {
      await prefs.remove(_kPending);
    } else {
      await prefs.setString(
        _kPending,
        jsonEncode(<String, Object?>{
          'uploads': uploads,
          'deletes': deletes,
          'directory': ?directory,
        }),
      );
    }
    await prefs.remove(_kPendingUploads);
    await prefs.remove(_kPendingDeletes);
  }

  ({List<String> uploads, List<String> deletes, String? directory})
  _decodePending(String raw) {
    final Object? decoded = jsonDecode(raw);
    if (decoded is! Map) {
      return (uploads: const <String>[], deletes: const <String>[], directory: null);
    }
    return (
      uploads: _stringList(decoded['uploads']),
      deletes: _stringList(decoded['deletes']),
      directory: decoded['directory'] is String
          ? decoded['directory'] as String
          : null,
    );
  }

  List<String> _stringList(Object? value) {
    if (value is! List) return const <String>[];
    return [for (final item in value) if (item is String) item];
  }

  Future<S3Config> s3Config() async {
    final prefs = await SharedPreferences.getInstance();
    return S3Config.fromRaw(
      endpoint: prefs.getString(_kS3Endpoint),
      region: prefs.getString(_kS3Region),
      bucket: prefs.getString(_kS3Bucket),
      accessKeyId: prefs.getString(_kS3AccessKeyId),
      secretAccessKey: prefs.getString(_kS3SecretAccessKey),
    );
  }

  Future<void> setS3Config(S3Config config) async {
    final prefs = await SharedPreferences.getInstance();
    // Trim only, don't normalize: a blank field is stored as '' (not the
    // default), so [s3Config] keeps applying the current default on read.
    await prefs.setString(_kS3Endpoint, config.endpoint.trim());
    await prefs.setString(_kS3Region, config.region.trim());
    await prefs.setString(_kS3Bucket, config.bucket.trim());
    await prefs.setString(_kS3AccessKeyId, config.accessKeyId);
    await prefs.setString(_kS3SecretAccessKey, config.secretAccessKey);
  }
}
