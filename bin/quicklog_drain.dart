import 'dart:convert';
import 'dart:io';

import 'package:quicklog/services/s3_config.dart';
import 'package:quicklog/services/s3_drain.dart';
import 'package:quicklog/services/s3_object_client.dart';

/// Laptop-side Quicklog S3 tooling.
///
/// `--import` is the production path: every `ql-*.md` object is streamed to
/// stdout as one JSON object per line (`{"key":...,"content":...}`), an ack
/// line (`{"key":...,"ok":bool}`) is read from stdin after each note, and the
/// remote object is deleted only after an ok-ack. The consumer — the dotfiles
/// `scripts/quicklog-drain` wrapper — performs the actual taskwarrior import,
/// so the note line format lives in exactly one place (fish). A note whose
/// import fails (or a consumer that dies mid-run) is simply not deleted and
/// is retried on the next run. `--only KEY[,KEY...]` restricts the drain to
/// exactly the named keys (after the `ql-*.md` filter) so the E2E harness can
/// never touch a note that arrives mid-run; the production ql-* filtering
/// itself is unit-tested in test/s3_drain_test.dart.
///
/// `--dest DIR` is the legacy manual-recovery mode: drain objects into files
/// without importing anything.
///
/// `--keys` lists pending notes and `--delete KEY...` removes stuck objects;
/// both exist for inspection and cleanup.
///
/// Usage:
///   dart run bin/quicklog_drain.dart --import [--dry-run] [--limit N] [--only K1,K2]
///   dart run bin/quicklog_drain.dart --dest DIR [--dry-run] [--force] [--limit N] [--only K1,K2]
///   dart run bin/quicklog_drain.dart --keys [--limit N]
///   dart run bin/quicklog_drain.dart --delete KEY [KEY...]
void main(List<String> args) async {
  final opts = parseDrainArgs(args);
  if (opts == null) {
    _usage();
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

  // Build from exactly what configProblem validated.
  final client = MinioS3ObjectClient(config.normalized());

  void onError(String msg) => stderr.writeln('quicklog_drain: $msg');

  try {
    switch (opts.mode) {
      case DrainMode.import:
        if (opts.dryRun) {
          final keys = await listQuicklogKeys(
            client: client,
            limit: opts.limit,
            onlyKeys: _onlyKeySet(opts),
          );
          for (final key in keys) {
            stderr.writeln('would import: $key');
          }
          stderr.writeln('dry-run: ${keys.length} note(s) would be imported');
          return;
        }
        final summary = await streamQuicklogObjects(
          client: client,
          emitNote: (key, content) async {
            // One JSON object per line; stdout carries only this protocol.
            stdout.writeln(jsonEncode({'key': key, 'content': content}));
            // Flush before waiting for the ack so a piped consumer never
            // blocks on an empty buffer.
            await stdout.flush();
          },
          readAck: (key) async =>
              parseAckLine(_readLineSync(), expectedKey: key),
          limit: opts.limit,
          onlyKeys: _onlyKeySet(opts),
          onError: onError,
        );
        stderr.writeln(summary);
        if (!summary.ok) exitCode = 1;
      case DrainMode.keys:
        final keys = await listQuicklogKeys(client: client, limit: opts.limit);
        for (final key in keys) {
          stdout.writeln(key);
        }
      case DrainMode.delete:
        final summary = await deleteQuicklogObjects(
          client: client,
          keys: opts.keys,
          onError: onError,
        );
        stderr.writeln(summary);
        if (!summary.ok) exitCode = 1;
      case DrainMode.dest:
        final summary = await drainQuicklogObjects(
          client: client,
          destDir: Directory(opts.dest),
          dryRun: opts.dryRun,
          force: opts.force,
          limit: opts.limit,
          onlyKeys: _onlyKeySet(opts),
          onError: onError,
        );
        stderr.writeln(summary);
        if (!summary.ok) exitCode = 1;
    }
  }
  // Bucket listing/transport errors surface here as a single loud failure;
  // objects are never deleted on a run that did not complete.
  catch (e) {
    stderr.writeln('quicklog_drain: $e');
    exitCode = 1;
  }
}

Set<String>? _onlyKeySet(DrainOpts opts) =>
    opts.onlyKeys.isEmpty ? null : opts.onlyKeys.toSet();

String? _readLineSync() {
  try {
    return stdin.readLineSync();
  } catch (_) {
    // Undecodable ack or closed stream: treat like a vanished consumer.
    return null;
  }
}

void _usage() {
  stderr.writeln(
    'Usage: dart run bin/quicklog_drain.dart --import [--dry-run] [--limit N] [--only K1,K2]\n'
    '       dart run bin/quicklog_drain.dart --dest DIR [--dry-run] [--force] [--limit N] [--only K1,K2]\n'
    '       dart run bin/quicklog_drain.dart --keys [--limit N]\n'
    '       dart run bin/quicklog_drain.dart --delete KEY [KEY...]',
  );
}

/// Why [config] cannot be drained from, or null when it can: the credentials
/// are missing, or [config] as normalized ([S3Config.normalized], which is
/// what main() builds its client from) cannot back a client. Checked before
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

enum DrainMode { import, keys, delete, dest }

class DrainOpts {
  DrainOpts({
    required this.mode,
    this.dest = '',
    this.dryRun = false,
    this.force = false,
    this.limit,
    this.keys = const [],
    this.onlyKeys = const [],
  });

  final DrainMode mode;
  final String dest;
  final bool dryRun;
  final bool force;
  final int? limit;
  final List<String> keys;
  final List<String> onlyKeys;
}

/// Parses the CLI into exactly one mode plus its valid flags; anything
/// ambiguous or incomplete returns null (usage error). Public (and therefore
/// unit-testable in test/quicklog_drain_args_test.dart) — the test imports
/// this file directly.
DrainOpts? parseDrainArgs(List<String> args) {
  var mode = DrainMode.import;
  var modeSeen = false;
  var dest = '';
  var dryRun = false;
  var force = false;
  int? limit;
  final keys = <String>[];
  final onlyKeys = <String>[];

  for (var i = 0; i < args.length; i++) {
    final a = args[i];
    switch (a) {
      case '--import':
        if (modeSeen) return null;
        mode = DrainMode.import;
        modeSeen = true;
      case '--keys':
        if (modeSeen) return null;
        mode = DrainMode.keys;
        modeSeen = true;
      case '--dest':
        if (modeSeen || i + 1 >= args.length) return null;
        mode = DrainMode.dest;
        modeSeen = true;
        dest = args[++i];
      case '--delete':
        if (modeSeen) return null;
        mode = DrainMode.delete;
        modeSeen = true;
        // Consume following arguments as keys, but stop at the first
        // option-looking argument: note keys never start with '-', so
        // `--delete k --limit 2` used to silently swallow `--limit` and
        // `2` as keys. Any dash-prefixed follower is now a usage error.
        var sawKey = false;
        while (i + 1 < args.length && !args[i + 1].startsWith('-')) {
          keys.add(args[++i]);
          sawKey = true;
        }
        if (!sawKey || i + 1 < args.length) return null;
      case '--only':
        if (i + 1 >= args.length) return null;
        // Trim each part so `--only "a, b"` selects both keys instead of
        // silently keeping " b" (which matches nothing); parts that are
        // blank after trimming are usage errors.
        final parts = args[++i].split(',').map((k) => k.trim()).toList();
        if (parts.any((k) => k.isEmpty)) return null;
        onlyKeys.addAll(parts);
      case '--dry-run':
        dryRun = true;
      case '--force':
        force = true;
      case '--limit':
        if (i + 1 >= args.length) return null;
        limit = int.tryParse(args[++i]);
        // 0 would silently process nothing — that is a usage error.
        if (limit == null || limit <= 0) return null;
      case '-h':
      case '--help':
        return null;
      default:
        return null;
    }
  }

  if (!modeSeen) return null;

  // Flag/mode combinations that would silently do nothing are usage errors.
  if (force && mode != DrainMode.dest) return null;
  if (dryRun && mode != DrainMode.import && mode != DrainMode.dest) return null;
  // --only restricts a drain (import or dest); it is meaningless — and
  // therefore rejected — for the read-only --keys mode and --delete.
  if (onlyKeys.isNotEmpty &&
      (mode == DrainMode.keys || mode == DrainMode.delete)) {
    return null;
  }

  return DrainOpts(
    mode: mode,
    dest: dest,
    dryRun: dryRun,
    force: force,
    limit: limit,
    keys: List.unmodifiable(keys),
    onlyKeys: List.unmodifiable(onlyKeys),
  );
}
