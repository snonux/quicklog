import '../services/log_service.dart';
import '../services/merged_note_listing.dart';

/// Remembers the entry browser's per-row [NoteStore.firstLine] reads within
/// one load of the listing, so a rebuild reuses the read in flight or already
/// done instead of starting another (in S3 mode, a network GET per visible
/// row).
///
/// A read is keyed by note id, where the note was listed (the location
/// decides which backend is read) and the load generation. Listings carry no
/// ETag or modification time, so every new load reads each row once more:
/// changes made elsewhere (another device, a sync tool) show on any re-list,
/// and a failed read is retried then. Within a load, [invalidate] forgets a
/// note the browser may have changed without re-listing.
class FirstLineMemo {
  int? _generation;
  final Map<(String, NoteStorageLocation), Future<String>> _lines = {};

  /// The first line of [located] for load [generation], read from [store]
  /// only if this load has not read it yet. A new generation forgets all
  /// reads of the previous one.
  Future<String> firstLine(
    LocatedLogEntry located,
    NoteStore store, {
    required int generation,
  }) {
    if (generation != _generation) {
      _lines.clear();
      _generation = generation;
    }
    return _lines.putIfAbsent((
      located.id,
      located.location,
    ), () => store.firstLine(located.id));
  }

  /// Forgets note [id] in every location, so its next lookup reads again.
  void invalidate(String id) => _lines.removeWhere((key, _) => key.$1 == id);
}
