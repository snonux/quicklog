import 'dart:convert';
import 'dart:typed_data';

import 'package:minio/minio.dart';

import 's3_config.dart';

/// Low-level path-style S3 object ops used by [S3NoteStore].
///
/// Production uses [MinioS3ObjectClient]; tests inject [MemoryS3ObjectClient]
/// so CI never needs a live Garage.
abstract class S3ObjectClient {
  Future<void> putObject(String key, List<int> bytes, {String contentType});
  Future<List<int>> getObject(String key);
  Future<void> deleteObject(String key);

  /// Object keys under [prefix] (caller filters further if needed).
  Future<List<String>> listKeys({String prefix = ''});
}

/// True for missing-object / 404 responses — not transport failures.
///
/// [S3NoteStore] must not call its degrade hook for these: a bad id or absent
/// key is a normal read miss, not an S3 outage.
bool isMissingObjectError(Object error) {
  if (error is StateError) {
    final msg = error.message;
    return msg.contains('NoSuchKey') || msg.contains('404');
  }
  if (error is MinioS3Error) {
    final code = error.error?.code;
    if (code == 'NoSuchKey' ||
        code == 'NotFound' ||
        code == 'Not Found' ||
        code == 'NoSuchBucket') {
      return true;
    }
    final status = error.response?.statusCode;
    if (status == 404) return true;
  }
  final s = error.toString();
  return s.contains('NoSuchKey') ||
      s.contains('NotFound') ||
      RegExp(r'\b404\b').hasMatch(s);
}

/// Minio client forced to path-style against [S3Config] (Garage-friendly).
class MinioS3ObjectClient implements S3ObjectClient {
  MinioS3ObjectClient(this.config, {Minio? minio})
      : _minio = minio ??
            Minio(
              endPoint: config.host,
              port: config.port,
              useSSL: config.useSSL,
              accessKey: config.accessKeyId,
              secretKey: config.secretAccessKey,
              region: config.region,
              pathStyle: true,
            ),
        _bucket = config.bucket;

  final S3Config config;
  final Minio _minio;
  final String _bucket;

  @override
  Future<void> putObject(
    String key,
    List<int> bytes, {
    String contentType = 'text/markdown',
  }) async {
    final data = Uint8List.fromList(bytes);
    await _minio.putObject(
      _bucket,
      key,
      Stream<Uint8List>.value(data),
      size: data.length,
      metadata: {'content-type': contentType},
    );
  }

  @override
  Future<List<int>> getObject(String key) async {
    final stream = await _minio.getObject(_bucket, key);
    final builder = BytesBuilder(copy: false);
    await for (final chunk in stream) {
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  @override
  Future<void> deleteObject(String key) async {
    await _minio.removeObject(_bucket, key);
  }

  @override
  Future<List<String>> listKeys({String prefix = ''}) async {
    final result = await _minio.listAllObjects(
      _bucket,
      prefix: prefix,
      recursive: true,
    );
    return [
      for (final o in result.objects)
        if (o.key != null && o.key!.isNotEmpty) o.key!,
    ];
  }
}

/// In-memory fake used by unit tests (and widget smoke with fake-S3).
class MemoryS3ObjectClient implements S3ObjectClient {
  final Map<String, List<int>> objects = {};

  /// When non-null, the next call to any method throws this error then clears.
  Object? failNext;

  /// When set, every call throws this error.
  Object? alwaysFail;

  void _maybeFail() {
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
  }

  @override
  Future<List<int>> getObject(String key) async {
    _maybeFail();
    final data = objects[key];
    if (data == null) {
      throw StateError('NoSuchKey: $key');
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
