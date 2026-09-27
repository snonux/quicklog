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

  /// Settings as every reader sees them: [endpoint], [region] and [bucket]
  /// are trimmed, and a missing or blank one falls back to its default
  /// ([kDefaultS3Endpoint], [kDefaultS3Region], [kDefaultS3Bucket]). The
  /// credentials are taken verbatim (absent means empty), never trimmed.
  ///
  /// The single place stored preferences, the Preferences form, imported
  /// settings and the drain CLI's environment become an [S3Config]. The
  /// endpoint keeps its scheme as given; [host], [port] and [useSSL] add
  /// `https://` when it has none.
  factory S3Config.fromRaw({
    String? endpoint,
    String? region,
    String? bucket,
    String? accessKeyId,
    String? secretAccessKey,
  }) {
    return S3Config(
      endpoint: _trimmedOr(endpoint, kDefaultS3Endpoint),
      region: _trimmedOr(region, kDefaultS3Region),
      bucket: _trimmedOr(bucket, kDefaultS3Bucket),
      accessKeyId: accessKeyId ?? '',
      secretAccessKey: secretAccessKey ?? '',
    );
  }

  final String endpoint;
  final String region;
  final String bucket;
  final String accessKeyId;
  final String secretAccessKey;

  /// This config as `PreferencesService.s3Config` reads it back once stored
  /// (see [S3Config.fromRaw]). Validate this, not the raw form input, so a
  /// value that is only blank or space-padded is judged by what will be used.
  S3Config normalized() => S3Config.fromRaw(
    endpoint: endpoint,
    region: region,
    bucket: bucket,
    accessKeyId: accessKeyId,
    secretAccessKey: secretAccessKey,
  );

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
    final trimmed = _trimmedOr(raw, kDefaultS3Endpoint);
    if (trimmed.contains('://')) return trimmed;
    return 'https://$trimmed';
  }

  /// [raw] trimmed, or [fallback] when it is null or blank.
  static String _trimmedOr(String? raw, String fallback) {
    final trimmed = raw?.trim() ?? '';
    return trimmed.isEmpty ? fallback : trimmed;
  }
}
