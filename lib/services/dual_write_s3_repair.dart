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

  final Set<String> _uploads = {};
  final Set<String> _deletes = {};
  bool _loaded = false;
  Future<void> _chain = Future<void>.value();

  /// Runs [action] after any in-flight queue change. Overlapping replays
  /// queue instead of interleaving prefs writes.
  Future<T> _exclusive<T>(Future<T> Function() action) {
    final result = _chain.then((_) => action());
    _chain = result.then((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<void> enqueueUpload(String id) {
    return _exclusive(() => _enqueueUpload(id));
  }

  Future<void> enqueueDelete(String id) {
    return _exclusive(() => _enqueueDelete(id));
  }

  /// Drops either pending op for [id] after S3 has caught up.
  Future<void> clear(String id) => _exclusive(() => _clear(id));

  Future<bool> hasPending() {
    return _exclusive(() async {
      await _ensureLoaded();
      return _uploads.isNotEmpty || _deletes.isNotEmpty;
    });
  }

  /// Re-uploads queued ids from [local], then deletes queued ids on [s3].
  ///
  /// Each id is attempted once. Success, or an S3 object that is already
  /// gone, drops the id. A missing local file becomes a pending delete: the
  /// device no longer has text to put. Anything else stays queued.
  /// Returns how many ids were dropped.
  Future<int> replay({required NoteStore local, required NoteStore s3}) {
    return _exclusive(() => _replay(local: local, s3: s3));
  }

  Future<void> _ensureLoaded() async {
    if (_loaded) return;
    _loaded = true;
    final prefs = _prefs;
    if (prefs == null) return;
    _uploads.addAll(await prefs.dualWritePendingUploads());
    _deletes.addAll(await prefs.dualWritePendingDeletes());
  }

  Future<void> _persist() async {
    final prefs = _prefs;
    if (prefs == null) return;
    await prefs.setDualWritePendingUploads(_sorted(_uploads));
    await prefs.setDualWritePendingDeletes(_sorted(_deletes));
  }

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
    _deletes.remove(id);
    _uploads.add(id);
    await _persist();
  }

  Future<void> _enqueueDelete(String id) async {
    _requireNoteId(id);
    await _ensureLoaded();
    _uploads.remove(id);
    _deletes.add(id);
    await _persist();
  }

  Future<void> _clear(String id) async {
    await _ensureLoaded();
    final changed = _uploads.remove(id) || _deletes.remove(id);
    if (changed) await _persist();
  }

  Future<int> _replay({
    required NoteStore local,
    required NoteStore s3,
  }) async {
    await _ensureLoaded();
    var done = 0;
    for (final id in List<String>.of(_uploads)) {
      try {
        final text = await local.read(id);
        await s3.update(id, text);
        await _clear(id);
        done++;
      } on PathNotFoundException {
        // Nothing on device to put. Dropping the object matches the primary.
        await _enqueueDelete(id);
      } catch (_) {
        // Leave the upload queued for the next recovery.
      }
    }
    for (final id in List<String>.of(_deletes)) {
      try {
        await s3.delete(id);
        await _clear(id);
        done++;
      } catch (e) {
        if (!isMissingObjectError(e)) continue;
        await _clear(id);
        done++;
      }
    }
    return done;
  }
}
