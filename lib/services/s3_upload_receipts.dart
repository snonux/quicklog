import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'log_service.dart';
import 'preferences.dart';
import 's3_config.dart';

/// A successfully uploaded local snapshot must not be uploaded again merely
/// because another consumer drained the bucket. Edits become pending again.
class S3UploadReceipts {
  S3UploadReceipts({PreferencesService? preferences})
    : _prefs = preferences ?? PreferencesService();

  final PreferencesService _prefs;
  static Future<void> _writes = Future<void>.value();

  static String digest(String text) =>
      sha256.convert(utf8.encode(text)).toString();

  /// Opaque scope avoids retaining credentials or provider paths in receipts.
  static String scope(S3Config config, String localStoreKey) => digest(
    jsonEncode([
      config.endpoint.trim(),
      config.region.trim(),
      config.bucket.trim(),
      config.accessKeyId,
      localStoreKey,
    ]),
  );

  Future<List<LogEntry>> pending({
    required String scope,
    required NoteStore local,
    required List<LogEntry> entries,
  }) async {
    await _writes;
    await _prefs.reload();
    final receipts = await _prefs.s3UploadReceipts();
    final known = receipts[scope] ?? const <String, String>{};
    final pending = <LogEntry>[];
    for (final entry in entries) {
      try {
        final text = await local.read(entry.id);
        if (known[entry.id] != digest(text)) pending.add(entry);
      } catch (_) {
        // Unreadable files stay on device without provoking network traffic.
      }
    }
    return pending;
  }

  /// Acknowledge exactly the confirmed snapshot, never a later local edit.
  Future<void> confirm(String scope, String id, String text) {
    final result = _writes.then((_) async {
      if (_prefs.usesAtomicS3State) {
        await _prefs.confirmAtomicReceipt(scope, id, digest(text));
        return;
      }
      await _prefs.reload();
      final receipts = await _prefs.s3UploadReceipts();
      (receipts[scope] ??= {})[id] = digest(text);
      await _prefs.setS3UploadReceipts(receipts);
    });
    _writes = result.then((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }
}
