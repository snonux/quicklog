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

  final config = configFromEnv(Platform.environment);
  final problem = configProblem(config);
  if (problem != null) {
    stderr.writeln('quicklog_drain: $problem');
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

/// Why [config] cannot be drained from, or null when it can. Checked before
/// any client is built, so bad settings exit cleanly instead of throwing.
String? configProblem(S3Config config) {
  if (!config.hasCredentials) {
    return 'missing GARAGE_ACCESS_KEY_ID / '
        'GARAGE_SECRET_ACCESS_KEY (and related GARAGE_* env vars)';
  }
  final invalid = MinioS3ObjectClient.settingsError(config);
  return invalid == null ? null : 'invalid S3 settings: $invalid';
}

/// [S3Config] from the `GARAGE_*` variables in [env], with defaults.
S3Config configFromEnv(Map<String, String> env) {
  return S3Config.fromRaw(
    endpoint: env['GARAGE_ENDPOINT'],
    region: env['GARAGE_REGION'],
    bucket: env['GARAGE_BUCKET'],
    accessKeyId: env['GARAGE_ACCESS_KEY_ID'],
    secretAccessKey: env['GARAGE_SECRET_ACCESS_KEY'],
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
