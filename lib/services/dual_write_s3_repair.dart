import 'dart:async';
import 'dart:io';

import 'log_service.dart';
import 'preferences.dart';
import 'saf_note_store.dart';
import 's3_object_client.dart';

/// A dual-write change reached the device and missed S3.
///
/// [message] is the sentence shown to the user. The on-device copy is already
/// updated or removed; S3 is replayed later from [DualWriteS3Repair].
class DualWriteS3Pending implements Exception {
  DualWriteS3Pending._(this.message);

  /// Local text is saved; the bucket still has the previous object.
  factory DualWriteS3Pending.notUploaded(Object cause) {
    return DualWriteS3Pending._(
      'Saved on this device. The S3 copy was not updated and will be '
      're-uploaded when S3 is reachable. ($cause)',
    );
  }

  /// Local file is gone; the bucket object is still there.
  factory DualWriteS3Pending.notDeleted(Object cause) {
    return DualWriteS3Pending._(
      'Removed the on-device copy. The S3 copy was not deleted and will '
      'be removed when S3 is reachable. ($cause)',
    );
  }

  final String message;

  @override
  String toString() => message;
}

/// Pending dual-write repairs: note ids to re-upload or delete on S3.
///
/// The local file is the primary. When an S3 put or delete fails after the
/// local side has landed, the id is remembered and [replay] tries each id
/// once. A failure stays queued. S3-only mode does not use this queue.
///
/// Persisted when [preferences] is set, so a restart does not drop the
/// repair. A null [preferences] keeps the sets in memory (tests).
class DualWriteS3Repair {
  DualWriteS3Repair({PreferencesService? preferences}) : _prefs = preferences;

  final PreferencesService? _prefs;

  final Map<String, _RepairQueue> _queues = {};
  String _active = '';
  bool _loaded = false;

  /// The saved repair document could not be decoded. Replay is skipped and
  /// nothing is written back, so a bad value cannot replace itself or
  /// fail the note list.
  bool _persistBlocked = false;
  Future<void> _chain = Future<void>.value();

  static const Object _held = Object();

  /// Runs [action] after any in-flight queue change. Overlapping replays
  /// and dual-write saves queue instead of interleaving. A call made from
  /// inside [action] runs immediately so enqueue cannot deadlock on itself.
  Future<T> run<T>(Future<T> Function() action) {
    if (Zone.current[_held] == true) return action();
    final result = _chain.then(
      (_) => runZoned(action, zoneValues: {_held: true}),
    );
    _chain = result.then((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<void> enqueueUpload(String id) {
    return run(() async {
      await _ensureLoaded();
      _active = await _folderKey();
      await _enqueueUpload(id);
    });
  }

  Future<void> enqueueDelete(String id) {
    return run(() async {
      await _ensureLoaded();
      _active = await _folderKey();
      await _enqueueDelete(id);
    });
  }

  /// Drops either pending op for [id] in the notes directory in use now.
  Future<void> clear(String id) {
    return run(() async {
      await _ensureLoaded();
      _active = await _folderKey();
      await _clear(id);
    });
  }

  Future<bool> hasPending() {
    return run(() async {
      await _ensureLoaded();
      return _queues.values.any((queue) => !queue.isEmpty);
    });
  }

  /// Re-uploads queued ids from [local], then deletes queued ids on [s3].
  ///
  /// Each id is attempted once. Success, or an S3 object that is already
  /// gone, drops the id. A missing local file becomes a pending delete: the
  /// device no longer has text to put. Anything else stays queued.
  /// Returns how many ids were dropped.
  Future<int> replay({required NoteStore local, required NoteStore s3}) {
    return run(() => _replay(local: local, s3: s3));
  }

  Future<void> _ensureLoaded() async {
    if (_loaded) return;
    final prefs = _prefs;
    if (prefs == null) {
      _loaded = true;
      return;
    }
    // Load before marking loaded. A decode failure must not stick an empty
    // map that the next persist would write over the saved repairs, and it
    // must not fail every later read of the note list.
    try {
      final folders = await prefs.dualWritePendingFolders();
      for (final entry in folders.entries) {
        final queue = _queues.putIfAbsent(entry.key, _RepairQueue.new);
        queue.uploads.addAll(_noteIds(entry.value.uploads));
        queue.deletes.addAll(_noteIds(entry.value.deletes));
      }
    } on FormatException {
      _persistBlocked = true;
    }
    _loaded = true;
  }

  Future<void> _persist() async {
    if (_persistBlocked) return;
    final prefs = _prefs;
    if (prefs == null) return;
    final folders = <String, ({List<String> uploads, List<String> deletes})>{};
    for (final entry in _queues.entries) {
      if (entry.value.isEmpty) continue;
      folders[entry.key] = (
        uploads: _sorted(entry.value.uploads),
        deletes: _sorted(entry.value.deletes),
      );
    }
    await prefs.setDualWritePendingFolders(folders);
  }

  /// '' when nothing is persisted. Otherwise the notes directory in use now.
  Future<String> _folderKey() async {
    final prefs = _prefs;
    if (prefs == null) return '';
    return prefs.localStoreKey();
  }

  /// Folder [local] is replaying. In-memory repairs (no preferences) share
  /// one queue. A missing directory is not replayed: a missing parent looks
  /// the same as a missing note, and that must not delete the bucket object.
  String _replayKey(NoteStore local) {
    if (_prefs == null) return '';
    if (local is LocalNoteStore) return local.directory;
    if (local is SafNoteStore) return 'saf:${local.treeUri}';
    return _active;
  }

  Future<bool> _folderMissing(NoteStore local) async {
    if (_prefs == null) return false;
    try {
      if (local is LocalNoteStore) {
        return !await Directory(local.directory).exists();
      }
      if (local is SafNoteStore) {
        await local.list();
      }
      return false;
    } catch (_) {
      // A stat failure is not proof the notes were deleted.
      return true;
    }
  }

  _RepairQueue _queue() => _queues.putIfAbsent(_active, _RepairQueue.new);

  List<String> _sorted(Set<String> ids) {
    final list = ids.toList()..sort();
    return list;
  }

  void _requireNoteId(String id) {
    if (parseLogEntryId(id) == null) {
      throw ArgumentError.value(id, 'id', 'must match ql-YYMMDD-HHmmss.md');
    }
  }

  Iterable<String> _noteIds(List<String> ids) =>
      ids.where((id) => parseLogEntryId(id) != null);

  Future<void> _enqueueUpload(String id) async {
    _requireNoteId(id);
    await _ensureLoaded();
    if (_persistBlocked) {
      throw StateError(
        'Dual-write repairs could not be read and were not queued.',
      );
    }
    final queue = _queue();
    queue.deletes.remove(id);
    queue.uploads.add(id);
    await _persist();
  }

  Future<void> _enqueueDelete(String id) async {
    _requireNoteId(id);
    await _ensureLoaded();
    if (_persistBlocked) {
      throw StateError(
        'Dual-write repairs could not be read and were not queued.',
      );
    }
    final queue = _queue();
    queue.uploads.remove(id);
    queue.deletes.add(id);
    await _persist();
  }

  Future<void> _clear(String id) async {
    await _ensureLoaded();
    if (!_queues.containsKey(_active)) return;
    final queue = _queue();
    final changed = queue.uploads.remove(id) || queue.deletes.remove(id);
    if (queue.isEmpty) _queues.remove(_active);
    if (changed) await _persist();
  }

  /// True when [id] is gone from [s3], including when the delete call threw
  /// after the object was already removed. False when it should stay queued.
  Future<bool> _deleteOrMissing(NoteStore s3, String id) async {
    try {
      await s3.delete(id);
      return true;
    } catch (e) {
      if (isMissingObjectError(e)) return true;
    }
    try {
      await s3.read(id);
      return false;
    } catch (e) {
      return isMissingObjectError(e);
    }
  }

  /// After a put of [written], drop [id] only when the device file still
  /// matches. A missing folder leaves the queue entry as it is. A file that
  /// disappeared from a folder that still exists is deleted from [s3], then
  /// checked again so a file that returns during that delete is put back.
  Future<bool> _confirmPut({
    required NoteStore local,
    required NoteStore s3,
    required String id,
    required String written,
    bool deleteIfMissing = true,
  }) async {
    final String current;
    try {
      current = await local.read(id);
    } on PathNotFoundException {
      if (await _folderMissing(local)) return false;
      if (!deleteIfMissing) {
        // Already put the file back once. One more delete, then stop.
        // A file that is still gone is removed in this pass so the list
        // does not show an S3-only leftover until the next refresh.
        final removed = await _deleteOrMissing(s3, id);
        if (!removed) return false;
        try {
          final again = await local.read(id);
          try {
            await s3.update(id, again);
          } catch (_) {
            await _enqueueUpload(id);
            return false;
          }
          await _enqueueUpload(id);
          return false;
        } on PathNotFoundException {
          if (await _folderMissing(local)) return false;
          await _clear(id);
          return true;
        } catch (_) {
          return false;
        }
      }
      return _finishDelete(local: local, s3: s3, id: id);
    } catch (_) {
      await _enqueueUpload(id);
      return false;
    }
    if (current != written) {
      await _enqueueUpload(id);
      return false;
    }
    await _clear(id);
    return true;
  }

  /// Deletes [id] from [s3] when the device file is gone, then reads again.
  /// A file or folder that appears during the delete is not dropped.
  Future<bool> _finishDelete({
    required NoteStore local,
    required NoteStore s3,
    required String id,
  }) async {
    final removed = await _deleteOrMissing(s3, id);
    if (!removed) return false;
    final String? back;
    try {
      back = await local.read(id);
    } on PathNotFoundException {
      if (await _folderMissing(local)) return false;
      await _clear(id);
      return true;
    } catch (_) {
      return false;
    }
    try {
      await s3.update(id, back);
    } catch (_) {
      await _enqueueUpload(id);
      return false;
    }
    return _confirmPut(
      local: local,
      s3: s3,
      id: id,
      written: back,
      deleteIfMissing: false,
    );
  }

  Future<int> _replay({required NoteStore local, required NoteStore s3}) async {
    await _ensureLoaded();
    _active = _replayKey(local);
    final queue = _queues[_active];
    if (queue == null || queue.isEmpty) return 0;
    // A missing folder looks like every note is gone. Leave the queue until
    // that folder exists again, and never replay another folder's ids here.
    if (await _folderMissing(local)) return 0;
    var done = 0;
    {
      for (final id in List<String>.of(queue.uploads)) {
        final String text;
        try {
          text = await local.read(id);
        } on PathNotFoundException {
          // A missing folder is not a deleted note. Leave the upload queued.
          if (await _folderMissing(local)) continue;
          await _enqueueDelete(id);
          continue;
        } catch (_) {
          // Leave the upload queued for the next recovery.
          continue;
        }
        try {
          await s3.update(id, text);
        } catch (_) {
          continue;
        }
        // A save during the put leaves the newer device text queued.
        if (await _confirmPut(local: local, s3: s3, id: id, written: text)) {
          done++;
        }
      }
    }
    for (final id in List<String>.of(queue.deletes)) {
      String? restored;
      try {
        restored = await local.read(id);
      } on PathNotFoundException {
        // A missing folder is not a deleted note. Leave the delete queued.
        if (await _folderMissing(local)) continue;
        restored = null;
      } catch (_) {
        continue;
      }
      if (restored != null) {
        // The device has this note again. Local is the primary, so the
        // bucket must match it instead of being deleted.
        try {
          await s3.update(id, restored);
        } catch (_) {
          await _enqueueUpload(id);
          continue;
        }
        if (await _confirmPut(
          local: local,
          s3: s3,
          id: id,
          written: restored,
        )) {
          done++;
        }
        continue;
      }
      // The file can reappear while the delete is in flight. Local is
      // still the primary, so put it back instead of dropping the queue.
      if (await _finishDelete(local: local, s3: s3, id: id)) done++;
    }
    return done;
  }
}

class _RepairQueue {
  final Set<String> uploads = {};
  final Set<String> deletes = {};

  bool get isEmpty => uploads.isEmpty && deletes.isEmpty;
}
