import 'dart:async';

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
/// changes made elsewhere (another device, a sync tool) show on any re-list.
/// [NoteStore.firstLine] maps a failed read to '', and this memo keeps that
/// result for the rest of the load. A rebuild does not retry it; the next
/// load generation does. [remember] stores a line the caller already read
/// with [NoteStore.read] (which throws). A failed read is not remembered, so
/// the previous line stays until the next load.
///
/// Within a load, [invalidate] forgets a note the browser may have changed
/// without re-listing.
///
/// [peek] is the line once that read has completed, or been [remember]ed, so
/// a row scrolled back into view can show it on the first frame. It does not
/// start a read.
class FirstLineMemo {
  int? _generation;
  final Map<(String, NoteStorageLocation), Future<String>> _lines = {};
  final Map<(String, NoteStorageLocation), String> _resolved = {};

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
      _resolved.clear();
      _generation = generation;
    }
    final key = (located.id, located.location);
    return _lines.putIfAbsent(key, () {
      final future = store.firstLine(located.id);
      unawaited(
        future.then<void>(
          (line) {
            // Keep the line only while this future is still the one cached
            // for the generation. A later generation or invalidate drops it.
            if (_generation != generation || !identical(_lines[key], future)) {
              return;
            }
            _resolved[key] = line;
          },
          onError: (_, _) {
            // This listener must not report the error. The cached future
            // still completes with it, and the next generation reads again.
          },
        ),
      );
      return future;
    });
  }

  /// The line for [located] in this [generation], if that read has already
  /// completed or been [remember]ed. Null while it is still in flight, after
  /// [invalidate], or when this generation has not read the row. Does not
  /// start a read.
  String? peek(LocatedLogEntry located, {required int generation}) {
    if (generation != _generation) return null;
    return _resolved[(located.id, located.location)];
  }

  /// Stores [line] as the finished subtitle of [located] for [generation]
  /// without calling the store. [peek] then returns [line], including when
  /// [line] is empty, so the next frame is not blank. No-op when [generation]
  /// is not the current load: a read that finishes after a newer load, or
  /// before any load, must not overwrite what is showing.
  ///
  /// Returns whether the line was stored.
  bool remember(
    LocatedLogEntry located,
    String line, {
    required int generation,
  }) {
    if (_generation != generation) return false;
    final key = (located.id, located.location);
    // Already complete, so no listener: a later [invalidate] clears the line
    // and nothing asynchronous writes it back. A previous read's listener
    // no-ops because this future is no longer the one cached for [key].
    _lines[key] = Future<String>.value(line);
    _resolved[key] = line;
    return true;
  }

  /// Forgets note [id] in every location, so its next lookup reads again.
  void invalidate(String id) {
    _lines.removeWhere((key, _) => key.$1 == id);
    _resolved.removeWhere((key, _) => key.$1 == id);
  }
}
