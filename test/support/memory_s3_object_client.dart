import 'dart:convert';

import 'package:quicklog/services/s3_object_client.dart';

/// In-memory [S3ObjectClient] for unit tests and widget tests.
///
/// A missing key throws [S3MissingObjectError], the same condition production
/// Minio reports as `NoSuchKey`.
class MemoryS3ObjectClient implements S3ObjectClient {
  final Map<String, List<int>> objects = {};

  /// Total calls made against any method; lets tests assert a backend was
  /// never contacted at all (e.g. while the degrade window is active).
  int calls = 0;

  /// When non-null, the next call to any method throws this error then clears.
  Object? failNext;

  /// When set, every call throws this error.
  Object? alwaysFail;

  /// When non-null, the next [putObject] records the object and *then* throws
  /// this error — an upload that landed but whose response was lost.
  Object? putSucceedsButThrows;

  void _maybeFail() {
    calls++;
    final always = alwaysFail;
    if (always != null) throw always;
    final once = failNext;
    if (once != null) {
      failNext = null;
      throw once;
    }
  }

  @override
  Future<void> putObject(
    String key,
    List<int> bytes, {
    String contentType = 'text/markdown',
  }) async {
    _maybeFail();
    objects[key] = List<int>.from(bytes);
    final lost = putSucceedsButThrows;
    if (lost != null) {
      putSucceedsButThrows = null;
      throw lost;
    }
  }

  @override
  Future<List<int>> getObject(String key) async {
    _maybeFail();
    final data = objects[key];
    if (data == null) {
      throw S3MissingObjectError(key);
    }
    return List<int>.from(data);
  }

  @override
  Future<void> deleteObject(String key) async {
    _maybeFail();
    objects.remove(key);
  }

  @override
  Future<List<String>> listKeys({String prefix = ''}) async {
    _maybeFail();
    final keys = objects.keys.where((k) => k.startsWith(prefix)).toList()
      ..sort();
    return keys;
  }

  /// Convenience for tests that put UTF-8 Markdown.
  Future<void> putText(String key, String text) =>
      putObject(key, utf8.encode(text));
}
