import 'entry_handle.dart';
import 'log_service.dart';
import 'merged_note_listing.dart';
import 's3_note_store.dart';

/// Local + optional S3 stores for the entry browser when S3 is preferred.
class BrowserNoteSources {
  BrowserNoteSources({
    required this.local,
    this.s3,
    required this.mergeWhenS3Preferred,
    this.preferLocalReads = false,
    this.keepLocalCopies = false,
    this.s3SetupError,
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

  /// Set by [list] when an S3 LIST fails; local rows are still returned.
  bool s3ListFailed = false;

  /// Store used for read / firstLine of [located].
  /// Prefer S3 when the note lives only there, or when local-first reads do
  /// not apply; otherwise the local copy.
  NoteStore storeFor(LocatedLogEntry located) {
    final remote = s3;
    if (located.hasS3 &&
        remote != null &&
        !(preferLocalReads && located.hasLocal)) {
      return remote;
    }
    return local;
  }

  /// Handle for view/edit/delete. Reads use [storeFor]. Update and delete
  /// keep every backend that holds the note in sync.
  EntryHandle entryStore(LocatedLogEntry located) =>
      _BrowserEntryStore(this, located);

  /// Writes [text] to every backend that currently holds [located].
  ///
  /// Both backends are attempted even if one fails, so a single I/O error does
  /// not skip the other. The first error (if any) is rethrown after both tries.
  Future<void> update(LocatedLogEntry located, String text) async {
    Object? firstError;
    final remote = s3;
    if (located.hasS3 && remote != null) {
      try {
        await remote.update(located.id, text);
      } catch (e) {
        firstError = e;
      }
    }
    if (located.hasLocal) {
      try {
        await local.update(located.id, text);
      } catch (e) {
        firstError ??= e;
      }
    }
    if (firstError != null) throw firstError;
  }

  /// Deletes from every backend that holds [located].
  ///
  /// Same best-effort rule as [update]: attempt every side, then rethrow the
  /// first error so a partial delete is still visible to the caller.
  Future<void> delete(LocatedLogEntry located) async {
    Object? firstError;
    final remote = s3;
    if (located.hasS3 && remote != null) {
      try {
        await remote.delete(located.id);
      } catch (e) {
        firstError = e;
      }
    }
    if (located.hasLocal) {
      try {
        await local.delete(located.id);
      } catch (e) {
        firstError ??= e;
      }
    }
    if (firstError != null) throw firstError;
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
