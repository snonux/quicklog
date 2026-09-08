import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'log_service.dart';
import 's3_object_client.dart';

/// Summary of a drain run (fetch local, then delete remote).
class DrainSummary {
  const DrainSummary({
    this.fetched = 0,
    this.deleted = 0,
    this.skipped = 0,
    this.failed = 0,
  });

  final int fetched;
  final int deleted;
  final int skipped;
  final int failed;

  bool get ok => failed == 0;

  @override
  String toString() =>
      'fetched=$fetched deleted=$deleted skipped=$skipped failed=$failed';
}

/// Downloads matching `ql-*.md` objects to [destDir], then deletes them from
/// S3 only after a successful local write. Never deletes on write failure.
Future<DrainSummary> drainQuicklogObjects({
  required S3ObjectClient client,
  required Directory destDir,
  bool dryRun = false,
  bool force = false,
  int? limit,
}) async {
  if (!await destDir.exists()) {
    await destDir.create(recursive: true);
  }

  final keys = (await client.listKeys())
      .where((k) => parseLogEntryId(p.basename(k)) != null)
      .toList()
    ..sort();

  final selected = limit == null ? keys : keys.take(limit).toList();

  var fetched = 0;
  var deleted = 0;
  var skipped = 0;
  var failed = 0;

  for (final key in selected) {
    final basename = p.basename(key);
    final target = File(p.join(destDir.path, basename));

    if (await target.exists() && !force) {
      skipped++;
      continue;
    }

    if (dryRun) {
      fetched++;
      deleted++;
      continue;
    }

    try {
      final bytes = await client.getObject(key);
      final tmp = File(
        p.join(
          destDir.path,
          '.$basename.tmp.${DateTime.now().microsecondsSinceEpoch}',
        ),
      );
      await tmp.writeAsBytes(Uint8List.fromList(bytes), flush: true);
      final written = await tmp.length();
      if (written != bytes.length) {
        await tmp.delete();
        throw StateError(
          'size mismatch for $key: wrote $written, expected ${bytes.length}',
        );
      }
      if (await target.exists()) {
        await target.delete();
      }
      await tmp.rename(target.path);
      fetched++;

      await client.deleteObject(key);
      deleted++;
    } catch (_) {
      failed++;
    }
  }

  return DrainSummary(
    fetched: fetched,
    deleted: deleted,
    skipped: skipped,
    failed: failed,
  );
}
