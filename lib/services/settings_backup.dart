import 'dart:convert';

import 'preferences.dart';
import 's3_config.dart';
import 's3_session_controller.dart';
import 'storage.dart';

/// Identifies a Quicklog settings export. Matches the Android application id
/// so a file from one of the sibling apps is recognised as foreign.
const String kSettingsAppId = 'org.buetow.quicklog';

/// Marks the JSON document as a settings export (as opposed to, say, a note).
const String kSettingsFormat = 'quicklog-settings';

/// Bump when the layout of `settings` changes incompatibly. Readers accept any
/// version up to their own and reject newer ones with a clear message; adding
/// keys does not need a bump, because unknown keys are ignored on import.
const int kSettingsFormatVersion = 1;

/// A settings file that cannot be imported. [message] is shown to the user
/// as-is, so it says what is wrong in plain words.
class SettingsImportException implements Exception {
  const SettingsImportException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Every user setting Quicklog persists, in export form.
///
/// A null field means "not in the file": importing leaves the current value
/// alone. That keeps an older, smaller export importable after new settings
/// are added. [directory] uses the empty string for "app default", which is
/// distinct from null.
///
/// Not included: the S3 degrade window (`S3DegradedUntil`), which is transient
/// runtime state that expires on its own within an hour and would be wrong on
/// another install.
class QuicklogSettings {
  const QuicklogSettings({
    this.directory,
    this.autoLogSharedText,
    this.storageMode,
    this.s3Endpoint,
    this.s3Region,
    this.s3Bucket,
    this.s3AccessKeyId,
    this.s3SecretAccessKey,
  });

  /// Log directory, or '' for the platform default.
  final String? directory;
  final bool? autoLogSharedText;
  final StorageMode? storageMode;
  final String? s3Endpoint;
  final String? s3Region;
  final String? s3Bucket;
  final String? s3AccessKeyId;
  final String? s3SecretAccessKey;

  /// True when the export carries S3 credentials in plain text.
  bool get containsSecrets =>
      (s3AccessKeyId ?? '').isNotEmpty || (s3SecretAccessKey ?? '').isNotEmpty;

  Map<String, Object?> toJson() {
    final s3 = <String, Object?>{
      'endpoint': ?s3Endpoint,
      'region': ?s3Region,
      'bucket': ?s3Bucket,
      'accessKeyId': ?s3AccessKeyId,
      'secretAccessKey': ?s3SecretAccessKey,
    };
    return <String, Object?>{
      'directory': ?directory,
      'autoLogSharedText': ?autoLogSharedText,
      'storageMode': ?storageMode?.wireName,
      if (s3.isNotEmpty) 's3': s3,
    };
  }

  /// Parses the `settings` object of an export. Unknown keys are ignored so
  /// files written by a newer Quicklog still import; a known key with the
  /// wrong type is rejected rather than silently dropped.
  factory QuicklogSettings.fromJson(Map<String, Object?> json) {
    final s3Raw = json['s3'];
    if (s3Raw != null && s3Raw is! Map) {
      throw const SettingsImportException(
        'Invalid settings file: "s3" must be an object.',
      );
    }
    final s3 = s3Raw == null
        ? const <String, Object?>{}
        : Map<String, Object?>.from(s3Raw as Map);
    return QuicklogSettings(
      directory: _optString(json, 'directory'),
      autoLogSharedText: _optBool(json, 'autoLogSharedText'),
      storageMode: _optStorageMode(json, 'storageMode'),
      s3Endpoint: _optString(s3, 'endpoint', prefix: 's3.'),
      s3Region: _optString(s3, 'region', prefix: 's3.'),
      s3Bucket: _optString(s3, 'bucket', prefix: 's3.'),
      s3AccessKeyId: _optString(s3, 'accessKeyId', prefix: 's3.'),
      s3SecretAccessKey: _optString(s3, 'secretAccessKey', prefix: 's3.'),
    );
  }

  static String? _optString(
    Map<String, Object?> json,
    String key, {
    String prefix = '',
  }) {
    final v = json[key];
    if (v == null || v is String) return v as String?;
    throw SettingsImportException(
      'Invalid settings file: "$prefix$key" must be text.',
    );
  }

  static bool? _optBool(Map<String, Object?> json, String key) {
    final v = json[key];
    if (v == null || v is bool) return v as bool?;
    throw SettingsImportException(
      'Invalid settings file: "$key" must be true or false.',
    );
  }

  static StorageMode? _optStorageMode(Map<String, Object?> json, String key) {
    final raw = _optString(json, key);
    if (raw == null) return null;
    for (final mode in StorageMode.values) {
      if (mode.wireName == raw) return mode;
    }
    throw SettingsImportException(
      'Invalid settings file: unknown storage mode "$raw".',
    );
  }
}

/// A decoded, validated settings file.
class SettingsBackup {
  const SettingsBackup({
    required this.settings,
    required this.formatVersion,
    this.exportedAt,
  });

  final QuicklogSettings settings;
  final int formatVersion;

  /// When the file was written, if it says so (informational only).
  final DateTime? exportedAt;
}

/// Serialises [settings] as a versioned, human-readable JSON document.
String encodeSettingsBackup(
  QuicklogSettings settings, {
  required DateTime exportedAt,
}) {
  final doc = <String, Object?>{
    'app': kSettingsAppId,
    'format': kSettingsFormat,
    'formatVersion': kSettingsFormatVersion,
    'exportedAt': exportedAt.toUtc().toIso8601String(),
    'containsSecrets': settings.containsSecrets,
    'settings': settings.toJson(),
  };
  return '${const JsonEncoder.withIndent('  ').convert(doc)}\n';
}

/// Parses and validates a settings file. Throws [SettingsImportException]
/// with a user-facing message when the file is not a Quicklog settings export
/// this version can read.
SettingsBackup decodeSettingsBackup(String text) {
  final Object? doc;
  try {
    doc = jsonDecode(text);
  } on FormatException {
    throw const SettingsImportException(
      'Not a Quicklog settings file: the file is not valid JSON.',
    );
  }
  if (doc is! Map) {
    throw const SettingsImportException(
      'Not a Quicklog settings file: expected a JSON object.',
    );
  }
  final app = doc['app'];
  if (app != kSettingsAppId) {
    throw SettingsImportException(
      app is String
          ? 'This settings file belongs to "$app", not Quicklog.'
          : 'Not a Quicklog settings file: no app id.',
    );
  }
  if (doc['format'] != kSettingsFormat) {
    throw const SettingsImportException(
      'Not a Quicklog settings file: unknown format.',
    );
  }
  final version = doc['formatVersion'];
  if (version is! int || version < 1) {
    throw const SettingsImportException(
      'Invalid settings file: missing or bad format version.',
    );
  }
  if (version > kSettingsFormatVersion) {
    throw SettingsImportException(
      'This settings file uses format version $version, but this Quicklog '
      'only reads up to version $kSettingsFormatVersion. Update Quicklog and '
      'try again.',
    );
  }
  final settings = doc['settings'];
  if (settings is! Map) {
    throw const SettingsImportException(
      'Invalid settings file: no "settings" object.',
    );
  }
  final exportedAt = doc['exportedAt'];
  return SettingsBackup(
    settings: QuicklogSettings.fromJson(Map<String, Object?>.from(settings)),
    formatVersion: version,
    exportedAt: exportedAt is String ? DateTime.tryParse(exportedAt) : null,
  );
}

/// Reads the current settings out of storage and writes imported ones back.
class SettingsBackupService {
  SettingsBackupService({
    PreferencesService? preferences,
    S3SessionController? session,
    DateTime Function()? clock,
  }) : _prefs = preferences ?? PreferencesService(),
       _session = session ?? S3SessionController.instance,
       _clock = clock ?? DateTime.now;

  final PreferencesService _prefs;
  final S3SessionController _session;
  final DateTime Function() _clock;

  /// Every persisted setting, with the directory left as '' when defaulted.
  ///
  /// Saving Preferences stores whatever the Directory field shows, so an
  /// untouched default ends up stored as its resolved path. That path is
  /// exported as '' too, so a restore on another machine or install resolves
  /// its own default instead of pinning this one.
  Future<QuicklogSettings> collect() async {
    final s3 = await _prefs.s3Config();
    var directory = await _prefs.storedDirectory() ?? '';
    if (directory.isNotEmpty && directory == await defaultLogDirectory()) {
      directory = '';
    }
    return QuicklogSettings(
      directory: directory,
      autoLogSharedText: await _prefs.autoLogSharedText(),
      storageMode: await _prefs.storageMode(),
      s3Endpoint: s3.endpoint,
      s3Region: s3.region,
      s3Bucket: s3.bucket,
      s3AccessKeyId: s3.accessKeyId,
      s3SecretAccessKey: s3.secretAccessKey,
    );
  }

  Future<String> exportJson() async =>
      encodeSettingsBackup(await collect(), exportedAt: _clock());

  /// Writes every setting present in [settings]; absent ones keep their value.
  ///
  /// The storage mode goes through the session controller, like Save in
  /// Preferences, so the running app switches backends immediately.
  Future<void> apply(QuicklogSettings settings) async {
    final dir = settings.directory;
    if (dir != null) {
      if (dir.trim().isEmpty) {
        await _prefs.clearDirectory();
      } else {
        await _prefs.setDirectory(dir);
      }
    }
    final autoLog = settings.autoLogSharedText;
    if (autoLog != null) await _prefs.setAutoLogSharedText(autoLog);

    final current = await _prefs.s3Config();
    await _prefs.setS3Config(
      S3Config(
        endpoint: settings.s3Endpoint ?? current.endpoint,
        region: settings.s3Region ?? current.region,
        bucket: settings.s3Bucket ?? current.bucket,
        accessKeyId: settings.s3AccessKeyId ?? current.accessKeyId,
        secretAccessKey: settings.s3SecretAccessKey ?? current.secretAccessKey,
      ),
    );

    final mode = settings.storageMode;
    if (mode != null) await _session.setPreferredMode(mode);
  }

  /// Validates [text] and applies it. Nothing is written when validation
  /// fails, so a bad file never leaves settings half-imported.
  Future<SettingsBackup> importJson(String text) async {
    final backup = decodeSettingsBackup(text);
    await apply(backup.settings);
    return backup;
  }
}
