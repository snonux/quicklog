import '../services/log_service.dart';
import '../services/merged_note_listing.dart';

/// Remembers the entry browser's per-row [NoteStore.firstLine] reads, so a
/// rebuild reuses the read in flight or already done instead of starting
/// another one (in S3 mode, a network GET per visible row).
///
/// A row is keyed by its note id and where it was listed: the location
/// decides which backend is read, so a copy or move to S3 gives the row a new
/// key. Listings carry no ETag or modification time, so content changes are
/// invalidated explicitly: [invalidate] after the browser edits or deletes a
/// note, [clear] when the user asks for a fresh read (changes made elsewhere).
///
/// [NoteStore.firstLine] maps read errors to an empty string, so an empty
/// line may be a failed fetch. Such a line is kept only until the next
/// listing ([retain]); rebuilds in between share it, and the reload retries.
class FirstLineMemo {
  final Map<(String, NoteStorageLocation), _Read> _reads = {};

  /// Number of remembered rows.
  int get length => _reads.length;

  /// The first line of [located], read from [store] only if not remembered.
  Future<String> firstLine(LocatedLogEntry located, NoteStore store) {
    final key = (located.id, located.location);
    final remembered = _reads[key];
    if (remembered != null) return remembered.line;
    final read = _Read();
    read.line = store
        .firstLine(located.id)
        .then(
          (line) {
            read.retry = line.isEmpty;
            return line;
          },
          onError: (Object _) {
            // firstLine should not throw; if it does, show an empty subtitle as
            // it would for any unreadable note, and retry on the next listing.
            read.retry = true;
            return '';
          },
        );
    _reads[key] = read;
    return read.line;
  }

  /// Applies a new listing: forgets rows it no longer contains (deleted or
  /// moved notes) and rows whose last read came back empty, so a failed
  /// fetch is retried rather than remembered.
  void retain(Iterable<LocatedLogEntry> listed) {
    final keys = {for (final e in listed) (e.id, e.location)};
    _reads.removeWhere((key, read) => read.retry || !keys.contains(key));
  }

  /// Forgets every row of note [id], whatever its location (after an edit,
  /// a delete, or an upload to or removal from a backend).
  void invalidate(String id) => _reads.removeWhere((key, _) => key.$1 == id);

  /// Forgets everything.
  void clear() => _reads.clear();
}

class _Read {
  late final Future<String> line;

  /// True once the read settled with an empty line (or an error).
  bool retry = false;
}
