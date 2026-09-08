import 'dart:convert';

import 'log_service.dart';
import 's3_object_client.dart';

/// S3-backed [NoteStore]: object keys are `ql-YYMMDD-HHmmss.md` (same contract
/// as [LocalNoteStore]). Edit overwrites the same key.
class S3NoteStore implements NoteStore {
  S3NoteStore(
    this.client, {
    Future<void> Function()? onFailure,
  }) : _onFailure = onFailure;

  final S3ObjectClient client;
  final Future<void> Function()? _onFailure;

  Future<T> _guard<T>(Future<T> Function() op) async {
    try {
      return await op();
    } catch (e) {
      final hook = _onFailure;
      if (hook != null) {
        try {
          await hook();
        } catch (_) {
          // Degrade hook must not mask the original I/O error.
        }
      }
      rethrow;
    }
  }

  void _requireId(String id) {
    if (parseLogEntryId(id) == null) {
      throw ArgumentError.value(id, 'id', 'must match ql-YYMMDD-HHmmss.md');
    }
  }

  @override
  Future<LogEntry> create(String text, {DateTime? now}) {
    return _guard(() async {
      final stamp = now ?? DateTime.now();
      final id = logEntryIdFor(stamp);
      await client.putObject(id, utf8.encode(text));
      return LogEntry(id: id, timestamp: parseLogEntryId(id)!);
    });
  }

  @override
  Future<List<LogEntry>> list() {
    return _guard(() async {
      final keys = await client.listKeys(prefix: 'ql-');
      final entries = <LogEntry>[];
      for (final key in keys) {
        final ts = parseLogEntryId(key);
        if (ts == null) continue;
        entries.add(LogEntry(id: key, timestamp: ts));
      }
      entries.sort((a, b) => b.timestamp.compareTo(a.timestamp));
      return entries;
    });
  }

  @override
  Future<String> read(String id) {
    return _guard(() async {
      _requireId(id);
      final bytes = await client.getObject(id);
      return utf8.decode(bytes);
    });
  }

  @override
  Future<void> update(String id, String text) {
    return _guard(() async {
      _requireId(id);
      await client.putObject(id, utf8.encode(text));
    });
  }

  @override
  Future<void> delete(String id) {
    return _guard(() async {
      _requireId(id);
      await client.deleteObject(id);
    });
  }

  @override
  Future<String> firstLine(String id) async {
    try {
      return firstLineOf(await read(id));
    } catch (_) {
      return '';
    }
  }

  @override
  Future<String> preview(String id, {int maxChars = 200}) async {
    return previewOf(await read(id), maxChars: maxChars);
  }

  /// Cheap connectivity check for [S3SessionController.retryS3].
  Future<void> probe() => _guard(() => client.listKeys(prefix: 'ql-'));
}
