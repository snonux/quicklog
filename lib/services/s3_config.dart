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
}
