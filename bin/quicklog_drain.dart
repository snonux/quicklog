import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:quicklog/services/s3_config.dart';
import 'package:quicklog/services/s3_drain.dart';
import 'package:quicklog/services/s3_object_client.dart';

/// Drain `ql-*.md` from Garage/S3 into a local notes directory, then delete
/// remote objects. Credentials from the environment (see
/// `~/.config/garage/quicklog.env` / fish `taskwarrior::quicklog_drain`).
///
/// Usage:
///   dart run bin/quicklog_drain.dart [--dest DIR] [--dry-run] [--force] [--limit N]
void main(List<String> args) async {
  final opts = _parseArgs(args);
  if (opts == null) {
    stderr.writeln(
      'Usage: dart run bin/quicklog_drain.dart '
      '[--dest DIR] [--dry-run] [--force] [--limit N]',
    );
    exitCode = 64;
    return;
  }

  final config = _configFromEnv();
  if (!config.hasCredentials) {
    stderr.writeln(
      'quicklog_drain: missing GARAGE_ACCESS_KEY_ID / '
      'GARAGE_SECRET_ACCESS_KEY (and related GARAGE_* env vars)',
    );
    exitCode = 1;
    return;
  }

  final dest = Directory(opts.dest);
  final client = MinioS3ObjectClient(config);
  final summary = await drainQuicklogObjects(
    client: client,
    destDir: dest,
    dryRun: opts.dryRun,
    force: opts.force,
    limit: opts.limit,
    onError: (msg) => stderr.writeln('quicklog_drain: $msg'),
  );

  stdout.writeln(summary);
  if (!summary.ok) {
    exitCode = 1;
  }
}

S3Config _configFromEnv() {
  final env = Platform.environment;
  return S3Config(
    endpoint: env['GARAGE_ENDPOINT']?.trim().isNotEmpty == true
        ? env['GARAGE_ENDPOINT']!.trim()
        : kDefaultS3Endpoint,
    region: env['GARAGE_REGION']?.trim().isNotEmpty == true
        ? env['GARAGE_REGION']!.trim()
        : kDefaultS3Region,
    bucket: env['GARAGE_BUCKET']?.trim().isNotEmpty == true
        ? env['GARAGE_BUCKET']!.trim()
        : kDefaultS3Bucket,
    accessKeyId: env['GARAGE_ACCESS_KEY_ID'] ?? '',
    secretAccessKey: env['GARAGE_SECRET_ACCESS_KEY'] ?? '',
  );
}

class _Opts {
  _Opts({
    required this.dest,
    required this.dryRun,
    required this.force,
    required this.limit,
  });

  final String dest;
  final bool dryRun;
  final bool force;
  final int? limit;
}

_Opts? _parseArgs(List<String> args) {
  var dest = p.join(Platform.environment['HOME'] ?? '', 'Notes', 'Quicklog');
  var dryRun = false;
  var force = false;
  int? limit;

  for (var i = 0; i < args.length; i++) {
    final a = args[i];
    switch (a) {
      case '--dest':
        if (i + 1 >= args.length) return null;
        dest = args[++i];
      case '--dry-run':
        dryRun = true;
      case '--force':
        force = true;
      case '--limit':
        if (i + 1 >= args.length) return null;
        limit = int.tryParse(args[++i]);
        if (limit == null || limit < 0) return null;
      case '-h':
      case '--help':
        return null;
      default:
        return null;
    }
  }

  return _Opts(dest: dest, dryRun: dryRun, force: force, limit: limit);
}
