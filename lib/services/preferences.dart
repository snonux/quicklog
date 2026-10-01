import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import 'package:shared_preferences/shared_preferences.dart';

import 's3_config.dart';
import 's3_retry_schedule.dart';
import 'storage.dart';

const _kDirectory = 'Directory';
const _kScopedTreeUri = 'ScopedTreeUri';
const _kScopedTreeName = 'ScopedTreeName';
const _kAutoLogSharedText = 'AutoLogSharedText';
const _kStorageMode = 'StorageMode';
const _kDegradedUntil = 'S3DegradedUntil';
const _kRetryTimes = 'S3RetryTimes';
const _kRetryInBackground = 'S3RetryInBackground';
const _kUploadReceipts = 'S3UploadReceipts';
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
  PreferencesService({
    MethodChannel? atomicStateChannel,
    bool? useAtomicS3State,
  }) : _atomicState =
           atomicStateChannel ??
           const MethodChannel('org.buetow.quicklog/s3-state'),
       usesAtomicS3State = useAtomicS3State ?? Platform.isAndroid;

  final MethodChannel _atomicState;
  final bool usesAtomicS3State;

  Future<String> _legacyRepairDocument() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final raw = prefs.getString(_kPending);
    if (raw != null) return raw;
    return jsonEncode({
      'folders': {
        await directory(): {
          'uploads': prefs.getStringList(_kPendingUploads) ?? <String>[],
          'deletes': prefs.getStringList(_kPendingDeletes) ?? <String>[],
        },
      },
    });
  }

  Future<String> atomicRepairDocument() async {
    try {
      return (await _atomicState.invokeMethod<String>('repairRead', {
        'legacy': await _legacyRepairDocument(),
      }))!;
    } on PlatformException {
      throw const FormatException('S3 repairs could not be read.');
    }
  }

  Future<String?> repairRevision(String folder, String id) async {
    if (!usesAtomicS3State) return null;
    final root = jsonDecode(await atomicRepairDocument()) as Map;
    return ((root['folders'] as Map)[folder] as Map?)?['revisions']?[id]
        as String?;
  }

  Future<Map<String, ({List<String> uploads, List<String> deletes})>>
  mutateRepair(
    String folder,
    String id,
    String operation, {
    String? expectedRevision,
    bool checkRevision = false,
  }) async {
    try {
      final result = (await _atomicState
          .invokeMapMethod<String, dynamic>('repairMutate', {
            'legacy': await _legacyRepairDocument(),
            'folder': folder,
            'id': id,
            'operation': operation,
            'expectedRevision': expectedRevision,
            'checkRevision': checkRevision,
          }))!;
      await reload();
      return _decodeFolders(result['document'] as String);
    } on PlatformException {
      throw const FormatException('S3 repairs could not be updated.');
    }
  }

  Future<bool> clearCapturedFailure(DateTime? expected) async {
    if (usesAtomicS3State) {
      return await _atomicState.invokeMethod<bool>('clearFailure', {
            'expected': expected?.toUtc().toIso8601String(),
          }) ??
          false;
    }
    await reload();
    final current = await degradedUntil();
    if (await storageMode() != StorageMode.s3 ||
        (current?.microsecondsSinceEpoch != expected?.microsecondsSinceEpoch)) {
      return false;
    }
    await setDegradedUntil(null);
    return true;
  }

  Future<void> confirmAtomicReceipt(
    String scope,
    String id,
    String digest,
  ) async {
    await _atomicState.invokeMethod<void>('receiptConfirm', {
      'scope': scope,
      'id': id,
      'digest': digest,
    });
    await reload();
  }

  /// Background engines have their own preference cache. Refresh before
  /// deciding whether a queued job still targets the selected settings.
  Future<void> reload() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
  }

  Future<S3RetrySchedule> s3RetrySchedule() async {
    final prefs = await SharedPreferences.getInstance();
    try {
      return S3RetrySchedule.parse(
        prefs.getStringList(_kRetryTimes) ?? const [],
      );
    } on FormatException {
      // A damaged schedule is disabled rather than making startup fail.
      return S3RetrySchedule(const []);
    }
  }

  Future<void> setS3RetrySchedule(S3RetrySchedule schedule) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_kRetryTimes, schedule.times);
  }

  Future<bool> s3RetryInBackground() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_kRetryInBackground) ?? false;
  }

  Future<void> setS3RetryInBackground(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kRetryInBackground, enabled);
  }

  /// Receipt keys and content hashes are transient state, never exported.
  Future<Map<String, Map<String, String>>> s3UploadReceipts() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kUploadReceipts);
    if (raw == null) return {};
    final decoded = jsonDecode(raw);
    if (decoded is! Map) throw const FormatException('Invalid S3 receipts.');
    return decoded.map((scope, notes) {
      if (scope is! String || notes is! Map) {
        throw const FormatException('Invalid S3 receipts.');
      }
      return MapEntry(
        scope,
        notes.map((id, digest) {
          if (id is! String || digest is! String) {
            throw const FormatException('Invalid S3 receipt.');
          }
          return MapEntry(id, digest);
        }),
      );
    });
  }

  Future<void> setS3UploadReceipts(
    Map<String, Map<String, String>> receipts,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kUploadReceipts, jsonEncode(receipts));
  }

  Future<({String uri, String name})?> scopedFolder() async {
    final prefs = await SharedPreferences.getInstance();
    final uri = prefs.getString(_kScopedTreeUri);
    if (uri == null || uri.isEmpty) return null;
    return (
      uri: uri,
      name: prefs.getString(_kScopedTreeName) ?? 'Selected folder',
    );
  }

  Future<void> setScopedFolder(String uri, String name) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kScopedTreeUri, uri);
    await prefs.setString(_kScopedTreeName, name);
  }

  Future<void> clearScopedFolder() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kScopedTreeUri);
    await prefs.remove(_kScopedTreeName);
  }

  /// A repair queue belongs to one local destination, never another.
  Future<String> localStoreKey() async {
    final folder = await scopedFolder();
    return folder == null ? directory() : 'saf:${folder.uri}';
  }

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
    final folders = await dualWritePendingFolders();
    final ids = <String>{for (final queue in folders.values) ...queue.uploads};
    return _sortedIds(ids);
  }

  /// Dual-write note ids removed on device whose S3 object is still there.
  Future<List<String>> dualWritePendingDeletes() async {
    final folders = await dualWritePendingFolders();
    final ids = <String>{for (final queue in folders.values) ...queue.deletes};
    return _sortedIds(ids);
  }

  /// Repair ids grouped by the notes directory they were queued in.
  ///
  /// One preference value, so a crash cannot save one folder's list without
  /// the other. Ids from a later directory stay in their own group.
  Future<Map<String, ({List<String> uploads, List<String> deletes})>>
  dualWritePendingFolders() async {
    final prefs = await SharedPreferences.getInstance();
    if (usesAtomicS3State) return _decodeFolders(await atomicRepairDocument());
    final raw = prefs.getString(_kPending);
    if (raw != null) return _decodeFolders(raw);
    final uploads = List<String>.from(
      prefs.getStringList(_kPendingUploads) ?? const <String>[],
    );
    final deletes = List<String>.from(
      prefs.getStringList(_kPendingDeletes) ?? const <String>[],
    );
    if (uploads.isEmpty && deletes.isEmpty) return {};
    return {await directory(): (uploads: uploads, deletes: deletes)};
  }

  Future<void> setDualWritePendingFolders(
    Map<String, ({List<String> uploads, List<String> deletes})> folders,
  ) async {
    if (usesAtomicS3State) {
      throw StateError(
        'Android repairs must be changed through atomic per-note operations.',
      );
    }
    final prefs = await SharedPreferences.getInstance();
    final kept = <String, Object>{};
    for (final entry in folders.entries) {
      if (entry.value.uploads.isEmpty && entry.value.deletes.isEmpty) {
        continue;
      }
      kept[entry.key] = <String, Object>{
        'uploads': entry.value.uploads,
        'deletes': entry.value.deletes,
      };
    }
    if (kept.isEmpty) {
      await prefs.remove(_kPending);
    } else {
      await prefs.setString(
        _kPending,
        jsonEncode(<String, Object>{'folders': kept}),
      );
    }
    await prefs.remove(_kPendingUploads);
    await prefs.remove(_kPendingDeletes);
  }

  Map<String, ({List<String> uploads, List<String> deletes})> _decodeFolders(
    String raw,
  ) {
    final Object? decoded = jsonDecode(raw);
    if (decoded is! Map) {
      throw const FormatException('DualWritePending is not an object');
    }
    final grouped = decoded['folders'];
    if (grouped is Map) {
      final folders =
          <String, ({List<String> uploads, List<String> deletes})>{};
      for (final entry in grouped.entries) {
        if (entry.key is! String || entry.value is! Map) {
          throw const FormatException(
            'DualWritePending folder entry is unreadable',
          );
        }
        final body = entry.value as Map;
        folders[entry.key as String] = (
          uploads: _stringList(body['uploads']),
          deletes: _stringList(body['deletes']),
        );
      }
      return folders;
    }
    if (grouped != null) {
      throw const FormatException('DualWritePending folders is not an object');
    }
    final directory = decoded['directory'];
    if (directory is! String ||
        (!decoded.containsKey('uploads') && !decoded.containsKey('deletes'))) {
      throw const FormatException('DualWritePending has no folders');
    }
    return {
      directory: (
        uploads: _stringList(decoded['uploads']),
        deletes: _stringList(decoded['deletes']),
      ),
    };
  }

  List<String> _sortedIds(Set<String> ids) {
    final list = ids.toList()..sort();
    return list;
  }

  List<String> _stringList(Object? value) {
    if (value == null) return const <String>[];
    if (value is! List || value.any((item) => item is! String)) {
      throw const FormatException('DualWritePending list is unreadable');
    }
    return [for (final item in value) item as String];
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
