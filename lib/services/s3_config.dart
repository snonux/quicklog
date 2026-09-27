import 'dart:io';

/// Defaults targeting Garage path-style at garage.f3s.buetow.org.
const String kDefaultS3Endpoint = 'https://garage.f3s.buetow.org';
const String kDefaultS3Region = 'garage';
const String kDefaultS3Bucket = 'quicklog';

/// User-configured S3 connection settings (never logged; secrets on-device only).
class S3Config {
  const S3Config({
    required this.endpoint,
    required this.region,
    required this.bucket,
    required this.accessKeyId,
    required this.secretAccessKey,
  });

  final String endpoint;
  final String region;
  final String bucket;
  final String accessKeyId;
  final String secretAccessKey;

  bool get hasCredentials =>
      accessKeyId.trim().isNotEmpty && secretAccessKey.trim().isNotEmpty;

  /// Host-only endpoint for the Minio client (no scheme/path).
  String get host {
    final uri = Uri.parse(_normalizeEndpoint(endpoint));
    if (uri.host.isEmpty) {
      throw FormatException('S3 endpoint has no host: $endpoint');
    }
    return uri.host;
  }

  bool get useSSL {
    final uri = Uri.parse(_normalizeEndpoint(endpoint));
    if (uri.scheme == 'http') return false;
    return true;
  }

  int get port {
    final uri = Uri.parse(_normalizeEndpoint(endpoint));
    if (uri.hasPort) return uri.port;
    return useSSL ? 443 : 80;
  }

  static String _normalizeEndpoint(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return kDefaultS3Endpoint;
    if (trimmed.contains('://')) return trimmed;
    return 'https://$trimmed';
  }

  factory S3Config.defaults({
    String accessKeyId = '',
    String secretAccessKey = '',
  }) {
    return S3Config(
      endpoint: kDefaultS3Endpoint,
      region: kDefaultS3Region,
      bucket: kDefaultS3Bucket,
      accessKeyId: accessKeyId,
      secretAccessKey: secretAccessKey,
    );
  }

  /// Builds a config from the standard `GARAGE_*` environment variables as
  /// loaded from `~/.config/garage/quicklog.env` by the laptop-side wrappers
  /// (the quicklog-drain script, taskwarrior::quicklog_import, the E2E
  /// harness). Empty variables fall back to the Garage defaults; missing
  /// credentials keep [hasCredentials] false so callers can report it.
  factory S3Config.fromEnvironment([Map<String, String>? env]) {
    final e = env ?? Platform.environment;

    String value(String name) {
      final raw = e[name] ?? '';
      final trimmed = raw.trim();
      return trimmed.isNotEmpty ? trimmed : _fallbackFor(name);
    }

    return S3Config(
      endpoint: value('GARAGE_ENDPOINT'),
      region: value('GARAGE_REGION'),
      bucket: value('GARAGE_BUCKET'),
      accessKeyId: (e['GARAGE_ACCESS_KEY_ID'] ?? '').trim(),
      secretAccessKey: (e['GARAGE_SECRET_ACCESS_KEY'] ?? '').trim(),
    );
  }

  static String _fallbackFor(String name) {
    return switch (name) {
      'GARAGE_ENDPOINT' => kDefaultS3Endpoint,
      'GARAGE_REGION' => kDefaultS3Region,
      'GARAGE_BUCKET' => kDefaultS3Bucket,
      _ => '',
    };
  }
}
