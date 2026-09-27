import 'dart:io';

import 'package:path/path.dart' as p;

import 'dual_write_s3_repair.dart';
import 'entry_handle.dart';
import 'log_service.dart';
import 'merged_note_listing.dart';
import 's3_note_store.dart';
import 's3_object_client.dart';

/// Local + optional S3 stores for the entry browser when S3 is preferred.
class BrowserNoteSources {
  BrowserNoteSources({
    required this.local,
    this.s3,
    required this.mergeWhenS3Preferred,
    this.preferLocalReads = false,
    this.keepLocalCopies = false,
    this.s3SetupError,
    this.pendingRepairs,
  });

  final LocalNoteStore local;
  final S3NoteStore? s3;

  /// Why [s3] is null although S3 is preferred because the saved settings
  /// cannot build a client (e.g. an invalid endpoint); null otherwise.
  /// The browser shows it next to the list-failure banner.
  final String? s3SetupError;

  /// True when S3 is part of the write target (s3-only or dual): merged
  /// listing + location badges.
  final bool mergeWhenS3Preferred;

  /// True in dual-write mode: a note that exists in both places is read from
  /// the local copy (the trusted primary), so a transient S3 GET failure
  /// does not hide a note that is on disk. S3-only rows still read from S3.
  final bool preferLocalReads;

  /// True in dual-write mode: [uploadLocalToS3] copies a local-only note to
  /// S3 and keeps the local file, the on-device primary. Otherwise (s3-only
  /// mode) it moves the note and drops the local file after the upload.
  final bool keepLocalCopies;

  /// Set only in dual-write mode. Partial S3 failures are queued here so a
  /// later [replayPendingS3] can catch the bucket up. Null in s3-only mode,
  /// which keeps its existing failure behaviour.
  final DualWriteS3Repair? pendingRepairs;

  /// Set by [list] when an S3 LIST fails; local rows are still returned.
  bool s3ListFailed = false;

  /// Store used for read / firstLine of [located].
  /// Prefer S3 when the note lives only there, or when local-first reads do
  /// not apply; otherwise the local copy.
  NoteStore storeFor(LocatedLogEntry located) {
    final remote = s3;
    final deviceCopy = preferLocalReads &&
        (located.hasLocal || _deviceFileExists(located.id));
    if (located.hasS3 && remote != null && !deviceCopy) {
      return remote;
    }
    return local;
  }

  /// Dual-write reads the device file when it exists, even if a listing
  /// error showed the row as S3-only. Otherwise the editor would load the
  /// bucket text and save it over the device copy.
  bool _deviceFileExists(String id) {
    if (parseLogEntryId(id) == null) return false;
    return File(p.join(local.directory, id)).existsSync();
  }

  /// Handle for view/edit/delete. Reads use [storeFor]. Update and delete
  /// keep every backend that holds the note in sync.
  EntryHandle entryStore(LocatedLogEntry located) =>
      _BrowserEntryStore(this, located);

  /// Writes [text] to every backend that currently holds [located].
  ///
  /// Both backends are attempted even if one fails, so a single I/O error does
  /// not skip the other. The first error (if any) is rethrown after both tries.
  ///
  /// In dual-write mode ([pendingRepairs] set), an S3 put that fails after the
  /// local write landed is queued and reported as [DualWriteS3Pending]: the
  /// device has the new text, and [replayPendingS3] overwrites the bucket
  /// later. A failed LIST hides remote ids, so a local-only row is still
  /// written to S3 in that case. S3-only mode has no queue and still throws
  /// the raw S3 error. The attempt shares the repair lock with [replay] so a
  /// save cannot land after a replay has already read older text.
  Future<void> update(LocatedLogEntry located, String text) {
    final repairs = pendingRepairs;
    if (repairs == null) return _update(located, text);
    return repairs.run(() => _update(located, text));
  }

  Future<void> _update(LocatedLogEntry located, String text) async {
    located = await _includingLocalFile(located);
    Object? s3Error;
    Object? localError;
    final remote = s3;
    final s3Attempted = _shouldWriteS3(located);
    if (s3Attempted && remote != null) {
      try {
        await remote.update(located.id, text);
      } catch (e) {
        s3Error = e;
      }
    }
    if (located.hasLocal) {
      try {
        await local.update(located.id, text);
      } catch (e) {
        localError = e;
      }
    }
    final pending = await _recordUpdate(
      located,
      text: text,
      s3Attempted: s3Attempted,
      s3Error: s3Error,
      localError: localError,
    );
    if (pending != null) throw pending;
    final firstError = s3Error ?? localError;
    if (firstError != null) throw firstError;
  }

  /// Deletes from every backend that holds [located].
  ///
  /// Same best-effort rule as [update]: attempt every side, then rethrow the
  /// first error so a partial delete is still visible to the caller.
  ///
  /// In dual-write mode, a local delete that lands while the S3 delete fails
  /// is queued ([DualWriteS3Pending]) and removed from the bucket on
  /// [replayPendingS3]. Without that, the note comes back as S3-only. A
  /// failed LIST is treated the same way: the row looks local-only, but the
  /// object may still be in the bucket.
  Future<void> delete(LocatedLogEntry located) {
    final repairs = pendingRepairs;
    if (repairs == null) return _delete(located);
    return repairs.run(() => _delete(located));
  }

  Future<void> _delete(LocatedLogEntry located) async {
    located = await _includingLocalFile(located);
    Object? s3Error;
    Object? localError;
    final remote = s3;
    final s3Attempted = _shouldWriteS3(located);
    if (s3Attempted && remote != null) {
      try {
        await remote.delete(located.id);
      } catch (e) {
        s3Error = e;
      }
    }
    if (located.hasLocal) {
      try {
        await local.delete(located.id);
      } catch (e) {
        localError = e;
      }
    }
    final pending = await _recordDelete(
      located,
      s3Attempted: s3Attempted,
      s3Error: s3Error,
      localError: localError,
    );
    if (pending != null) throw pending;
    final firstError = s3Error ?? localError;
    if (firstError != null) throw firstError;
  }

  /// True when this write should touch S3. A note listed on S3 always does.
  /// In dual-write mode a failed LIST drops every remote id, so a local row
  /// is written too — otherwise an edit during the outage never reaches the
  /// bucket. A genuine local-only row after a successful LIST is left for
  /// the explicit upload action.
  bool _shouldWriteS3(LocatedLogEntry located) {
    if (s3 == null) return false;
    if (located.hasS3) return true;
    return pendingRepairs != null && s3ListFailed && located.hasLocal;
  }

  /// One pass over [pendingRepairs]. No-op without a queue or an S3 store.
  /// Does not loop: an id that fails stays queued for a later call.
  Future<void> replayPendingS3() async {
    final remote = s3;
    final repairs = pendingRepairs;
    if (remote == null || repairs == null) return;
    await repairs.replay(local: local, s3: remote);
  }

  /// A failed LIST, or a listing error, can show a note as S3-only while the
  /// device file is still there. Dual-write then has to write that file too.
  Future<LocatedLogEntry> _includingLocalFile(LocatedLogEntry located) async {
    if (pendingRepairs == null || located.hasLocal) return located;
    if (parseLogEntryId(located.id) == null) return located;
    if (!await File(p.join(local.directory, located.id)).exists()) {
      return located;
    }
    return LocatedLogEntry(
      entry: located.entry,
      location: NoteStorageLocation.both,
    );
  }

  Future<DualWriteS3Pending?> _recordUpdate(
    LocatedLogEntry located, {
    required String text,
    required bool s3Attempted,
    required Object? s3Error,
    required Object? localError,
  }) async {
    final repairs = pendingRepairs;
    if (repairs == null) return null;
    final localLanded = located.hasLocal && localError == null;
    if (s3Attempted &&
        s3Error == null &&
        (localLanded || !located.hasLocal)) {
      // Both copies match, or this row is only on S3 (a leftover after a
      // queued delete). Either way the bucket has the text just written,
      // so a pending delete must not run and remove it.
      await repairs.clear(located.id);
      return null;
    }
    // S3 accepted this text and the device write did not. Leave a queued
    // upload in place so replay can put the device text back. Do not add a
    // new one: the device file does not contain this attempt, and enqueueing
    // it would not change that.
    if (localLanded && s3Error != null && s3Error is! ArgumentError) {
      await repairs.enqueueUpload(located.id);
      return DualWriteS3Pending.notUploaded(s3Error);
    }
    if (s3Attempted &&
        s3Error != null &&
        !located.hasLocal &&
        s3Error is! ArgumentError) {
      final onBucket = await _bucketText(located.id);
      // New text, or a read that cannot show the object is unchanged:
      // a queued delete must not remove an edit that may have landed.
      if (onBucket == null || onBucket == text) {
        await repairs.clear(located.id);
      }
    }
    return null;
  }

  /// Bucket text, or null when it cannot be read.
  Future<String?> _bucketText(String id) async {
    final remote = s3;
    if (remote == null) return null;
    try {
      return await remote.read(id);
    } catch (_) {
      return null;
    }
  }

  Future<bool> _objectMissing(String id) async {
    final remote = s3;
    if (remote == null) return false;
    try {
      await remote.read(id);
      return false;
    } catch (e) {
      return isMissingObjectError(e);
    }
  }

  Future<DualWriteS3Pending?> _recordDelete(
    LocatedLogEntry located, {
    required bool s3Attempted,
    required Object? s3Error,
    required Object? localError,
  }) async {
    final repairs = pendingRepairs;
    if (repairs == null) return null;
    final localRemoved = located.hasLocal && localError == null;
    var s3Gone =
        s3Attempted && (s3Error == null || isMissingObjectError(s3Error));
    if (s3Attempted &&
        !s3Gone &&
        s3Error is! ArgumentError &&
        await _objectMissing(located.id)) {
      // The object is gone even though the delete call reported failure.
      s3Gone = true;
    }
    if (s3Gone && (localRemoved || !located.hasLocal)) {
      await repairs.clear(located.id);
      return null;
    }
    if (s3Gone && localError != null) {
      // The bucket object is gone and the device file is not. Replay puts
      // that file back; clearing would leave the note only on the device.
      await repairs.enqueueUpload(located.id);
      return null;
    }
    if (localRemoved && s3Error != null && s3Error is! ArgumentError) {
      await repairs.enqueueDelete(located.id);
      return DualWriteS3Pending.notDeleted(s3Error);
    }
    return null;
  }

  /// Drops the local copy of a note that already exists in S3 (finishes a
  /// partial move, or clears a duplicate after a failed local delete).
  Future<void> removeLocalCopy(LocatedLogEntry located) async {
    if (located.location != NoteStorageLocation.both) {
      throw StateError(
        'Only notes present in both places can drop the local copy.',
      );
    }
    await local.delete(located.id);
  }

  /// Uploads a local-only note to S3: a copy when [keepLocalCopies] (the
  /// note ends up in both places), otherwise a move (local file deleted only
  /// after a successful put).
  Future<void> uploadLocalToS3(LocatedLogEntry located) async {
    final remote = s3;
    if (remote == null) {
      throw StateError('S3 is not available to receive the note.');
    }
    if (!located.isLocalOnly) {
      throw StateError('Only local-only notes can be uploaded to S3.');
    }
    final upload = keepLocalCopies ? copyLocalNoteToS3 : moveLocalNoteToS3;
    await upload(local: local, s3: remote, id: located.id);
  }

  /// Lists notes from these sources (merged when [mergeWhenS3Preferred]).
  Future<List<LocatedLogEntry>> list() async {
    s3ListFailed = false;
    final localEntries = await local.list();
    if (!mergeWhenS3Preferred) {
      return [
        for (final e in localEntries)
          LocatedLogEntry(entry: e, location: NoteStorageLocation.local),
      ];
    }
    List<LogEntry> s3Entries = const [];
    final remote = s3;
    if (remote != null) {
      try {
        s3Entries = await remote.list();
      } catch (_) {
        // Degrade hook (if any) already ran inside S3NoteStore; keep local
        // rows so a failing bucket does not blank the whole browser.
        s3ListFailed = true;
        s3Entries = const [];
      }
    } else if (mergeWhenS3Preferred) {
      // Preferred S3 but no client (missing credentials or an invalid
      // endpoint, see [s3SetupError]): treat as a list miss.
      s3ListFailed = true;
    }
    return mergeNoteLists(local: localEntries, s3: s3Entries);
  }
}

/// Routes read to the preferred backend and write/delete through
/// [BrowserNoteSources] so [NoteStorageLocation.both] stays consistent.
///
/// Bound to [_located]: there is no id argument to apply the write to a
/// different note, and no create.
class _BrowserEntryStore implements EntryHandle {
  _BrowserEntryStore(this._sources, this._located);

  final BrowserNoteSources _sources;
  final LocatedLogEntry _located;

  NoteStore get _primary => _sources.storeFor(_located);

  @override
  LogEntry get entry => _located.entry;

  @override
  String get id => _located.id;

  @override
  Future<String> read() => _primary.read(id);

  @override
  Future<void> update(String text) => _sources.update(_located, text);

  @override
  Future<void> delete() => _sources.delete(_located);

  @override
  Future<String> firstLine() => _primary.firstLine(id);

  @override
  Future<String> preview({int maxChars = 200}) =>
      _primary.preview(id, maxChars: maxChars);
}
