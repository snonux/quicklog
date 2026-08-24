import 'dart:io';

import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;

class LogEntry {
  LogEntry({required this.file, required this.timestamp});
  final File file;
  final DateTime timestamp;
}

final _filenameRegex = RegExp(r'^ql-(\d{6})-(\d{6})\.md$');
final _timestampFormat = DateFormat('yyMMdd-HHmmss');

Future<File> logEntry(String dir, String text, {DateTime? now}) async {
  // Create the target directory if missing so a fresh, app-owned folder
  // (e.g. a Storage Scopes destination the app hasn't been granted access
  // to yet) still works: apps can freely write files/folders they created.
  await Directory(dir).create(recursive: true);
  final stamp = _timestampFormat.format(now ?? DateTime.now());
  final file = File(p.join(dir, 'ql-$stamp.md'));
  await file.writeAsString(text);
  return file;
}

Future<List<LogEntry>> listEntries(String dir) async {
  final directory = Directory(dir);
  final entries = <LogEntry>[];
  try {
    // GrapheneOS Storage Scopes can report a directory as existing while
    // still denying the actual listing, so treat that as "no entries yet"
    // rather than surfacing an error for a folder the user hasn't scoped.
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is! File) continue;
      final ts = _parseFilename(p.basename(entity.path));
      if (ts == null) continue;
      entries.add(LogEntry(file: entity, timestamp: ts));
    }
  } on FileSystemException {
    return const [];
  }
  entries.sort((a, b) => b.timestamp.compareTo(a.timestamp));
  return entries;
}

/// Permanently removes an entry file. There is no trash folder, so callers
/// must confirm with the user first (see confirmEntryDeletion). Missing files
/// are treated as already deleted rather than as an error, which keeps a
/// stale list (e.g. after a Syncthing sync) from throwing.
Future<void> deleteEntry(File f) async {
  if (await f.exists()) await f.delete();
}

/// First line of an entry, used as the list subtitle. Unreadable files yield
/// an empty string so one bad file cannot break the whole listing.
Future<String> entryFirstLine(File f) async {
  try {
    final content = await f.readAsString();
    final i = content.indexOf('\n');
    return i < 0 ? content : content.substring(0, i);
  } catch (_) {
    return '';
  }
}

/// Leading [maxChars] characters of an entry, ellipsised when truncated.
/// Used by the delete confirmation screen to show what is about to be lost
/// without loading a huge note into a widget tree.
Future<String> entryPreview(File f, {int maxChars = 200}) async {
  final content = await f.readAsString();
  if (content.length <= maxChars) return content;
  return '${content.substring(0, maxChars)}\u2026';
}

DateTime? _parseFilename(String name) {
  final m = _filenameRegex.firstMatch(name);
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
