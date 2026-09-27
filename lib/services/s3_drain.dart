import 'dart:convert';
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
    this.aborted = false,
  });

  final int fetched;
  final int deleted;
  final int skipped;
  final int failed;

  /// True when an import-stream run stopped early because the consumer went
  /// away or desynced. Nothing further was emitted or deleted in that case.
  final bool aborted;

  bool get ok => failed == 0 && !aborted;

  @override
  String toString() =>
      'fetched=$fetched deleted=$deleted skipped=$skipped failed=$failed'
      '${aborted ? ' aborted' : ''}';
}

/// The import consumer's verdict for one streamed note: imported (delete the
/// remote object) or failed (keep it for the next run).
class ImportAck {
  const ImportAck({required this.ok});

  final bool ok;
}

/// Parses one ack line (`{"key":"...","ok":true}`) sent by the import
/// consumer for the note just emitted as [expectedKey].
///
/// Returns null for a missing line (the consumer went away), a non-JSON
/// line, a mismatched key, or a missing `ok` flag — the drain treats all of
/// these as fatal and stops without deleting anything else.
ImportAck? parseAckLine(String? line, {required String expectedKey}) {
  if (line == null) return null;
  final trimmed = line.trim();
  if (trimmed.isEmpty) return null;
  final Object decoded;
  try {
    decoded = jsonDecode(trimmed);
  } catch (_) {
    return null;
  }
  if (decoded is! Map<String, dynamic>) return null;
  if (decoded['key'] != expectedKey) return null;
  final ok = decoded['ok'];
  return ok is bool ? ImportAck(ok: ok) : null;
}

/// Lists the `ql-*.md` keys currently in the bucket, oldest first, with
/// [limit] applied.
///
/// When [onlyKeys] is non-null, the listed keys are additionally restricted
/// to exactly those (after the `ql-*.md` contract filter and before
/// [limit]). This exists for the E2E harness, which drains only its own
/// test keys so a note arriving mid-run can never be consumed by a test —
/// the production `ql-*` filtering itself stays in place and tested.
Future<List<String>> listQuicklogKeys({
  required S3ObjectClient client,
  int? limit,
  Set<String>? onlyKeys,
}) async {
  var keys = (await client.listKeys())
      .where((k) => parseLogEntryId(p.basename(k)) != null)
      .toList()
    ..sort();
  if (onlyKeys != null) {
    keys = keys.where(onlyKeys.contains).toList();
  }
  return limit == null ? keys : keys.take(limit).toList();
}

/// Reads one note object as text. Keys whose basename does not match the
/// `ql-*.md` contract are rejected without contacting S3, and undecodable
/// bytes become replacement characters so one corrupt note cannot wedge the
/// pipeline forever.
Future<String> readQuicklogObject({
  required S3ObjectClient client,
  required String key,
}) async {
  if (parseLogEntryId(p.basename(key)) == null) {
    throw ArgumentError('not a quicklog note key: $key');
  }
  final bytes = await client.getObject(key);
  return utf8.decode(bytes, allowMalformed: true);
}

/// Deletes the given note objects, reporting each failure through [onError].
/// Keys outside the `ql-*.md` contract are refused.
Future<DrainSummary> deleteQuicklogObjects({
  required S3ObjectClient client,
  required List<String> keys,
  void Function(String message)? onError,
}) async {
  var deleted = 0;
  var failed = 0;
  for (final key in keys) {
    if (parseLogEntryId(p.basename(key)) == null) {
      failed++;
      onError?.call('refusing to delete non-quicklog key: $key');
      continue;
    }
    try {
      await client.deleteObject(key);
      deleted++;
    } catch (e) {
      failed++;
      onError?.call('delete failed for $key: $e');
    }
  }
  return DrainSummary(deleted: deleted, failed: failed);
}

/// Streams each `ql-*.md` object to [emitNote] one at a time (oldest key
/// first, [limit] and [onlyKeys] applied) and deletes the remote object
/// only after the consumer acknowledged the note as imported — so a failed
/// import is retried on the next run instead of being lost.
///
/// Known duplicate window, by design: a delete that fails *after* an ok-ack
/// leaves an already-imported note queued (see the delete-failure test) —
/// the next run re-emits it and the consumer's dedup must suppress the
/// duplicate lines.
///
/// Protocol per note: [emitNote] hands the note's [content] to the consumer
/// (usually one JSON object per stdout line); [readAck] then returns the
/// consumer's verdict. A null ack means the consumer went away or desynced —
/// the whole run aborts immediately and nothing further is emitted or
/// deleted. `ok:false` skips the delete (note retried later); `ok:true`
/// deletes the remote object. Read failures count as failed and the run
/// continues with the next note.
Future<DrainSummary> streamQuicklogObjects({
  required S3ObjectClient client,
  required Future<void> Function(String key, String content) emitNote,
  required Future<ImportAck?> Function(String key) readAck,
  int? limit,
  Set<String>? onlyKeys,
  void Function(String message)? onError,
}) async {
  final keys =
      await listQuicklogKeys(client: client, limit: limit, onlyKeys: onlyKeys);

  var fetched = 0;
  var deleted = 0;
  var skipped = 0;
  var failed = 0;
  var aborted = false;

  for (final key in keys) {
    final String content;
    try {
      content = await readQuicklogObject(client: client, key: key);
    } catch (e) {
      failed++;
      onError?.call('read failed for $key: $e');
      continue;
    }

    try {
      await emitNote(key, content);
    } catch (e) {
      failed++;
      onError?.call('emit failed for $key: $e');
      continue;
    }

    final ack = await readAck(key);
    if (ack == null) {
      // Consumer vanished or desynced: stop without deleting anything else.
      aborted = true;
      onError?.call('import consumer went away after $key; aborting run');
      break;
    }
    if (!ack.ok) {
      failed++;
      onError?.call('import failed for $key: kept for retry');
      continue;
    }

    fetched++;
    try {
      await client.deleteObject(key);
      deleted++;
    } catch (e) {
      // The note was already imported (ok-ack) but stays queued, so the
      // next run re-emits it and the consumer's dedup must suppress the
      // duplicate lines — the one accepted duplicate window.
      failed++;
      onError?.call('delete failed for $key after import: $e');
    }
  }

  return DrainSummary(
    fetched: fetched,
    deleted: deleted,
    skipped: skipped,
    failed: failed,
    aborted: aborted,
  );
}

/// Downloads matching `ql-*.md` objects to [destDir], then deletes them from
/// S3 only after a successful local write. Never deletes on write failure.
Future<DrainSummary> drainQuicklogObjects({
  required S3ObjectClient client,
  required Directory destDir,
  bool dryRun = false,
  bool force = false,
  int? limit,
  Set<String>? onlyKeys,
  void Function(String message)? onError,
}) async {
  if (!dryRun && !await destDir.exists()) {
    await destDir.create(recursive: true);
  }

  final keys =
      await listQuicklogKeys(client: client, limit: limit, onlyKeys: onlyKeys);
  var fetched = 0;
  var deleted = 0;
  var skipped = 0;
  var failed = 0;

  for (final key in keys) {
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
      // Re-check immediately before write so a racing local create still skips
      // unless --force (no unconditional delete of collisions).
      if (await target.exists() && !force) {
        skipped++;
        continue;
      }

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
      // Final collision check immediately before publish — a peer (e.g.
      // Syncthing) may have created the file during GET.
      if (await target.exists() && !force) {
        await tmp.delete();
        skipped++;
        continue;
      }
      // On Linux, rename over an existing file is atomic; do not delete first.
      await tmp.rename(target.path);
      fetched++;

      try {
        await client.deleteObject(key);
        deleted++;
      } catch (e) {
        failed++;
        onError?.call('delete failed for $key after local write: $e');
      }
    } catch (e) {
      failed++;
      onError?.call('drain failed for $key: $e');
    }
  }

  return DrainSummary(
    fetched: fetched,
    deleted: deleted,
    skipped: skipped,
    failed: failed,
  );
}
