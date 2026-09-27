import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:quicklog/services/log_service.dart';
import 'package:quicklog/services/s3_config.dart';
import 'package:quicklog/services/s3_object_client.dart';

/// Dev/test helper: put one Quicklog note object into the bucket, reading the
/// note content from stdin. Not part of the app — the dotfiles
/// `scripts/quicklog-drain-e2e` harness uses it to stage fixtures in a real
/// Garage bucket (create → verify → delete) for the end-to-end import test.
///
/// Usage:
///   dart run tool/put_note.dart KEY   (note content on stdin)
void main(List<String> args) async {
  if (args.length != 1) {
    stderr.writeln('Usage: dart run tool/put_note.dart KEY');
    exitCode = 64;
    return;
  }
  final key = args[0];
  if (parseLogEntryId(p.basename(key)) == null) {
    stderr.writeln('put_note: not a quicklog note key: $key');
    exitCode = 64;
    return;
  }

  final config = S3Config.fromEnvironment();
  if (!config.hasCredentials) {
    stderr.writeln('put_note: missing GARAGE_* credentials in environment');
    exitCode = 1;
    return;
  }

  final content = await utf8.decoder.bind(stdin).join();
  await MinioS3ObjectClient(config).putObject(key, utf8.encode(content));
  stderr.writeln('put_note: stored $key (${content.length} chars)');
}