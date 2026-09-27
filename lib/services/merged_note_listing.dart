import 'log_service.dart';

/// Where a listed note currently lives when S3 is preferred.
enum NoteStorageLocation {
  /// Present only under the local notes directory.
  local,

  /// Present only in the S3 bucket.
  s3,

  /// Same id exists in both places (e.g. a dual-write note, a local note
  /// copied to S3 in dual-write mode, or a failed move).
  both,
}

/// A [LogEntry] annotated with where it was found.
class LocatedLogEntry {
  const LocatedLogEntry({required this.entry, required this.location});

  final LogEntry entry;
  final NoteStorageLocation location;

  String get id => entry.id;
  DateTime get timestamp => entry.timestamp;

  bool get isLocalOnly => location == NoteStorageLocation.local;
  bool get hasLocal =>
      location == NoteStorageLocation.local ||
      location == NoteStorageLocation.both;
  bool get hasS3 =>
      location == NoteStorageLocation.s3 ||
      location == NoteStorageLocation.both;
}

/// Unions [local] and [s3] by id, newest first. Duplicate ids become [both].
List<LocatedLogEntry> mergeNoteLists({
  required List<LogEntry> local,
  required List<LogEntry> s3,
}) {
  final localById = {for (final e in local) e.id: e};
  final s3ById = {for (final e in s3) e.id: e};
  final ids = {...localById.keys, ...s3ById.keys};
  final merged = <LocatedLogEntry>[];
  for (final id in ids) {
    final localEntry = localById[id];
    final s3Entry = s3ById[id];
    final NoteStorageLocation location;
    final LogEntry entry;
    if (localEntry != null && s3Entry != null) {
      location = NoteStorageLocation.both;
      // Same id contract ⇒ same timestamp; prefer either.
      entry = s3Entry;
    } else if (localEntry != null) {
      location = NoteStorageLocation.local;
      entry = localEntry;
    } else {
      location = NoteStorageLocation.s3;
      entry = s3Entry!;
    }
    merged.add(LocatedLogEntry(entry: entry, location: location));
  }
  merged.sort((a, b) => b.timestamp.compareTo(a.timestamp));
  return merged;
}

/// Uploads a local note to S3 under the same id and keeps the local file
/// (dual-write mode: the note ends up in both places).
Future<void> copyLocalNoteToS3({
  required NoteStore local,
  required NoteStore s3,
  required String id,
}) async {
  final text = await local.read(id);
  await s3.update(id, text);
}

/// Uploads a local-only note to S3, then deletes the local file only after a
/// successful put (mirrors drain's "delete after success" rule, opposite
/// direction).
Future<void> moveLocalNoteToS3({
  required NoteStore local,
  required NoteStore s3,
  required String id,
}) async {
  await copyLocalNoteToS3(local: local, s3: s3, id: id);
  await local.delete(id);
}
