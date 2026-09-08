import 'dart:io';

import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;

/// A log note identity. [id] is the basename / object key (`ql-….md`), not a
/// filesystem path — local and remote stores both use the same contract.
class LogEntry {
  LogEntry({required this.id, required this.timestamp});
  final String id;
  final DateTime timestamp;
}

/// Persistence façade for log entries. Implementations map [LogEntry.id] to a
/// file under a directory or an object in a bucket; callers never hold [File].
abstract class NoteStore {
  Future<LogEntry> create(String text, {DateTime? now});
  Future<List<LogEntry>> list();
  Future<String> read(String id);
  Future<void> update(String id, String text);
  Future<void> delete(String id);

  /// First line of an entry, used as the list subtitle. Unreadable notes
  /// yield an empty string so one bad entry cannot break the whole listing.
  Future<String> firstLine(String id);

  /// Leading [maxChars] characters, ellipsised when truncated. Used by the
  /// delete confirmation screen. Unlike [firstLine], read errors propagate.
  Future<String> preview(String id, {int maxChars = 200});
}

final _filenameRegex = RegExp(r'^ql-(\d{6})-(\d{6})\.md$');
final _timestampFormat = DateFormat('yyMMdd-HHmmss');

/// Filesystem-backed [NoteStore] writing `ql-YYMMDD-HHmmss.md` under [directory].
/// Same filename contract Syncthing / quicklogger already expect.
class LocalNoteStore implements NoteStore {
  LocalNoteStore(this.directory);

  final String directory;

  File _fileFor(String id) => File(p.join(directory, id));

  @override
  Future<LogEntry> create(String text, {DateTime? now}) async {
    // Create the target directory if missing so a fresh, app-owned folder
    // (e.g. a Storage Scopes destination the app hasn't been granted access
    // to yet) still works: apps can freely write files/folders they created.
    await Directory(directory).create(recursive: true);
    final stamp = now ?? DateTime.now();
    final id = 'ql-${_timestampFormat.format(stamp)}.md';
    await _fileFor(id).writeAsString(text);
    return LogEntry(id: id, timestamp: stamp);
  }

  @override
  Future<List<LogEntry>> list() async {
    final dir = Directory(directory);
    final entries = <LogEntry>[];
    try {
      // GrapheneOS Storage Scopes can report a directory as existing while
      // still denying the actual listing, so treat that as "no entries yet"
      // rather than surfacing an error for a folder the user hasn't scoped.
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is! File) continue;
        final id = p.basename(entity.path);
        final ts = parseLogEntryId(id);
        if (ts == null) continue;
        entries.add(LogEntry(id: id, timestamp: ts));
      }
    } on FileSystemException {
      return const [];
    }
    entries.sort((a, b) => b.timestamp.compareTo(a.timestamp));
    return entries;
  }

  /// Permanently removes an entry. There is no trash folder, so callers must
  /// confirm with the user first (see confirmEntryDeletion). Missing notes
  /// are treated as already deleted rather than as an error, which keeps a
  /// stale list (e.g. after a Syncthing sync) from throwing.
  @override
  Future<void> delete(String id) async {
    final f = _fileFor(id);
    if (await f.exists()) await f.delete();
  }

  @override
  Future<String> firstLine(String id) async {
    try {
      return firstLineOf(await read(id));
    } catch (_) {
      return '';
    }
  }

  @override
  Future<String> preview(String id, {int maxChars = 200}) async {
    return previewOf(await read(id), maxChars: maxChars);
  }

  /// Full text of an entry, for the editor.
  ///
  /// Unlike [firstLine] this lets read errors propagate: the editor must not
  /// silently start from an empty buffer, because saving that would wipe a
  /// note that is present but momentarily unreadable.
  @override
  Future<String> read(String id) => _fileFor(id).readAsString();

  /// Overwrites an existing entry with edited [text].
  ///
  /// The filename encodes when the note was *created*, so an edit reuses the
  /// same id instead of writing a new one: the entry keeps its place in the
  /// list and sync peers see an update rather than a duplicate. Writes can
  /// fail for files the app did not create (Storage Scopes / scoped storage),
  /// so the error is left to the caller to report to the user.
  @override
  Future<void> update(String id, String text) async {
    await _fileFor(id).writeAsString(text);
  }
}

/// First line of [content], or the whole string when there is no newline.
String firstLineOf(String content) {
  final i = content.indexOf('\n');
  return i < 0 ? content : content.substring(0, i);
}

/// Leading [maxChars] characters of [content], ellipsised when truncated.
String previewOf(String content, {int maxChars = 200}) {
  if (content.length <= maxChars) return content;
  return '${content.substring(0, maxChars)}\u2026';
}

/// Parses a `ql-YYMMDD-HHmmss.md` id into its creation timestamp, or null
/// when the name does not match the contract.
DateTime? parseLogEntryId(String id) {
  final m = _filenameRegex.firstMatch(id);
  if (m == null) return null;
  final d = m.group(1)!; // YYMMDD
  final t = m.group(2)!; // HHMMSS
  try {
    return DateTime(
      2000 + int.parse(d.substring(0, 2)),
      int.parse(d.substring(2, 4)),
      int.parse(d.substring(4, 6)),
      int.parse(t.substring(0, 2)),
      int.parse(t.substring(2, 4)),
      int.parse(t.substring(4, 6)),
    );
  } catch (_) {
    return null;
  }
}
