import 'dart:async';
import 'dart:io';

import 'log_service.dart';
import 'preferences.dart';
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
    return run(() => _enqueueUpload(id));
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
    _loaded = true;
    final prefs = _prefs;
    if (prefs == null) return;
    final folders = await prefs.dualWritePendingFolders();
    for (final entry in folders.entries) {
      final queue = _queues.putIfAbsent(entry.key, _RepairQueue.new);
      queue.uploads.addAll(entry.value.uploads);
      queue.deletes.addAll(entry.value.deletes);
    }
  }

  Future<void> _persist() async {
    final prefs = _prefs;
    if (prefs == null) return;
    final folders =
        <String, ({List<String> uploads, List<String> deletes})>{};
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
    return prefs.directory();
  }

  /// Folder [local] is replaying. In-memory repairs (no preferences) share
  /// one queue. A missing directory is not replayed: a missing parent looks
  /// the same as a missing note, and that must not delete the bucket object.
  String _replayKey(NoteStore local) {
    if (_prefs == null) return '';
    if (local is LocalNoteStore) return local.directory;
    return _active;
  }

  Future<bool> _folderMissing(NoteStore local) async {
    if (_prefs == null || local is! LocalNoteStore) return false;
    return !await Directory(local.directory).exists();
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

  Future<void> _enqueueUpload(String id) async {
    _requireNoteId(id);
    await _ensureLoaded();
    _active = await _folderKey();
    final queue = _queue();
    queue.deletes.remove(id);
    queue.uploads.add(id);
    await _persist();
  }

  Future<void> _enqueueDelete(String id) async {
    _requireNoteId(id);
    await _ensureLoaded();
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

  /// True when [id] is gone from [s3], including when it was already missing.
  /// False when the delete failed and the id should stay queued.
  Future<bool> _deleteOrMissing(NoteStore s3, String id) async {
    try {
      await s3.delete(id);
      return true;
    } catch (e) {
      return isMissingObjectError(e);
    }
  }

  Future<int> _replay({
    required NoteStore local,
    required NoteStore s3,
  }) async {
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
        try {
          final text = await local.read(id);
          await s3.update(id, text);
          // A save during the put leaves the newer device text queued.
          final current = await local.read(id);
          if (current != text) continue;
          await _clear(id);
          done++;
        } on PathNotFoundException {
          // Nothing in this folder to put. Dropping the object matches it.
          await _enqueueDelete(id);
        } catch (_) {
          // Leave the upload queued for the next recovery.
        }
      }
    }
    for (final id in List<String>.of(queue.deletes)) {
      String? restored;
      try {
        restored = await local.read(id);
      } on PathNotFoundException {
        restored = null;
      } catch (_) {
        continue;
      }
      if (restored != null) {
        // The device has this note again. Local is the primary, so the
        // bucket must match it instead of being deleted.
        try {
          await s3.update(id, restored);
          final current = await local.read(id);
          if (current != restored) {
            await _enqueueUpload(id);
            continue;
          }
          await _clear(id);
          done++;
        } catch (_) {
          await _enqueueUpload(id);
        }
        continue;
      }
      final removed = await _deleteOrMissing(s3, id);
      if (!removed) continue;
      // The file can reappear while the delete is in flight. Local is
      // still the primary, so put it back instead of dropping the queue.
      final String? back;
      try {
        back = await local.read(id);
      } on PathNotFoundException {
        await _clear(id);
        done++;
        continue;
      } catch (_) {
        continue;
      }
      try {
        await s3.update(id, back);
        final current = await local.read(id);
        if (current != back) {
          await _enqueueUpload(id);
          continue;
        }
        await _clear(id);
        done++;
      } catch (_) {
        await _enqueueUpload(id);
      }
    }
    return done;
  }
}

class _RepairQueue {
  final Set<String> uploads = {};
  final Set<String> deletes = {};

  bool get isEmpty => uploads.isEmpty && deletes.isEmpty;
}
