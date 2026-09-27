import 'browser_note_sources.dart';
import 'lazy_s3_note_store.dart';
import 'log_service.dart';
import 'merged_note_listing.dart';
import 'preferences.dart';
import 's3_config.dart';
import 's3_note_store.dart';
import 's3_object_client.dart';
import 's3_session_controller.dart';

typedef S3ObjectClientFactory = S3ObjectClient Function(S3Config config);

/// Where a newly created note ended up.
enum NoteCreateOutcome {
  /// Written to the backend(s) the mode targets.
  saved,

  /// S3 was part of the target (s3-only or dual) and the S3 write failed;
  /// the note is on the local device only. (A lost response can in theory
  /// leave a copy in the bucket as well — the browser then shows the note
  /// as present in both places.)
  savedLocalOnly,

  /// Dual write: the S3 copy landed but the local write failed; the note is
  /// in the bucket only.
  savedS3Only,

  /// S3 was part of the target but the saved S3 settings cannot build a
  /// client ([S3ConfigException], e.g. an invalid endpoint); the note is on
  /// the local device only. A settings mistake, not an outage, so no
  /// degrade window is armed: the fix is in Preferences.
  savedLocalS3SettingsInvalid,
}

/// The outcome of [ActiveNoteStore.createNote].
typedef NoteCreateResult = ({LogEntry entry, NoteCreateOutcome outcome});

/// The dual-write local copy, attempted before S3: written or failed.
sealed class _LocalAttempt {
  const _LocalAttempt();

  /// The written entry, or the captured failure rethrown with its original
  /// stack trace.
  LogEntry entryOrRethrow();
}

final class _LocalWritten extends _LocalAttempt {
  const _LocalWritten(this.entry);

  final LogEntry entry;

  @override
  LogEntry entryOrRethrow() => entry;
}

final class _LocalFailed extends _LocalAttempt {
  const _LocalFailed(this.error, this.stackTrace);

  final Object error;
  final StackTrace stackTrace;

  @override
  LogEntry entryOrRethrow() => Error.throwWithStackTrace(error, stackTrace);
}

/// Resolves the process-active [NoteStore] from prefs + [S3SessionController].
///
/// S3-only preferred (and not degraded) → [S3NoteStore]; otherwise
/// [LocalNoteStore] (dual-write mode reads the local copy; new notes go
/// through [createNote], which writes both backends). Wires
/// [S3SessionController.probe] for Retry and calls [markS3Failed] on
/// S3 I/O errors. The entry browser uses [resolveBrowserSources] to list both
/// backends when S3 is part of the target.
class ActiveNoteStore {
  ActiveNoteStore({
    PreferencesService? preferences,
    S3SessionController? session,
    S3ObjectClientFactory? s3ClientFactory,
  })  : _prefs = preferences ?? PreferencesService(),
        _session = session ?? S3SessionController.instance,
        _s3ClientFactory = s3ClientFactory ?? _defaultMinioFactory;

  static final ActiveNoteStore instance = ActiveNoteStore();

  final PreferencesService _prefs;
  final S3SessionController _session;
  final S3ObjectClientFactory _s3ClientFactory;
  bool _probeBound = false;

  S3SessionController get session => _session;

  static S3ObjectClient _defaultMinioFactory(S3Config config) =>
      MinioS3ObjectClient(config);

  /// Bind a LIST probe onto the session once (idempotent). Call after
  /// [S3SessionController.load] in [main].
  void bindSessionProbe() {
    if (_probeBound) return;
    _probeBound = true;
    _session.probe = () async {
      final store = await _buildS3Store(markFailures: true);
      await store.probe();
    };
  }

  /// Active store for create/list/read/update/delete.
  Future<NoteStore> resolve() async {
    bindSessionProbe();
    final dir = await _prefs.directory();
    if (_session.preferredMode == StorageMode.both) {
      // Dual write: reads prefer the local copy (present for notes created
      // in this mode); new notes go through createNote, which writes both.
      return LocalNoteStore(dir);
    }
    if (_session.shouldAttemptS3) {
      final config = await _prefs.s3Config();
      if (!config.hasCredentials) {
        // Preferred S3 but nothing to authenticate with: fall back to local
        // and arm degrade so the banner / retry path stay consistent.
        await _session.markS3Failed();
        return LocalNoteStore(dir);
      }
    }
    return _session.resolveStore(
      local: () => LocalNoteStore(dir),
      s3: () {
        // resolveStore expects a sync factory; build from last-known config
        // via a thin deferred wrapper that loads prefs on first use.
        return LazyS3NoteStore(() => _buildS3Store(markFailures: true));
      },
    );
  }

  /// Local directory store (always available).
  Future<LocalNoteStore> resolveLocal() async {
    final dir = await _prefs.directory();
    return LocalNoteStore(dir);
  }

  /// Creates a new note per the preferred [StorageMode]:
  ///
  /// - [StorageMode.local]: local directory only.
  /// - [StorageMode.s3]: S3 first; when the S3 write fails the note is
  ///   written to the local directory **immediately** (same timestamp, hence
  ///   the same `ql-*.md` id), so it lands on the first try instead of
  ///   waiting for a user retry.
  /// - [StorageMode.both]: dual write — the local copy is written first, then
  ///   S3 with the same id. An S3 failure still leaves the note safely on
  ///   device ([NoteCreateOutcome.savedLocalOnly]); a local failure still
  ///   keeps it in the bucket ([NoteCreateOutcome.savedS3Only]).
  ///
  /// When S3 is part of the target but the session is inside the degrade
  /// window, or no S3 credentials are saved, the note is written locally
  /// without contacting S3 ([NoteCreateOutcome.savedLocalOnly]); missing
  /// credentials also arm the degrade window. When the saved S3 settings
  /// cannot build a client, the note is kept locally as
  /// [NoteCreateOutcome.savedLocalS3SettingsInvalid] and no degrade window is
  /// armed — the fix is in Preferences. An [ArgumentError] from S3 is
  /// rethrown, unless a dual-write local copy already landed (then
  /// [NoteCreateOutcome.savedLocalOnly]).
  ///
  /// The same-second overwrite rule of [LocalNoteStore.create] applies in
  /// every mode (the id only has second granularity). If both backends fail,
  /// the local error is rethrown with its original stack trace — the note is
  /// nowhere.
  Future<NoteCreateResult> createNote(String text, {DateTime? now}) async {
    bindSessionProbe();
    final local = LocalNoteStore(await _prefs.directory());
    if (_session.preferredMode == StorageMode.local) {
      return _createLocal(local, text, now, NoteCreateOutcome.saved);
    }
    final config = await _s3ConfigForCreate();
    if (config == null) {
      return _createLocal(local, text, now, NoteCreateOutcome.savedLocalOnly);
    }
    final stamp = now ?? DateTime.now();
    return _session.preferredMode == StorageMode.both
        ? _createDual(local, config, text, stamp)
        : _createS3Only(local, config, text, stamp);
  }

  /// Writes the note to the local directory only and reports [outcome].
  Future<NoteCreateResult> _createLocal(
    LocalNoteStore local,
    String text,
    DateTime? now,
    NoteCreateOutcome outcome,
  ) async => (entry: await local.create(text, now: now), outcome: outcome);

  /// The S3 settings to create a note with, or null when S3 is part of the
  /// target but this note must go local-only without contacting it: inside
  /// the degrade window (no network timeout spent on every note), or without
  /// credentials (arms the degrade window so the banner / retry path stay
  /// consistent).
  Future<S3Config?> _s3ConfigForCreate() async {
    if (!_session.shouldAttemptS3) return null;
    final config = await _prefs.s3Config();
    if (config.hasCredentials) return config;
    await _session.markS3Failed();
    return null;
  }

  /// [StorageMode.s3]: the bucket first; when S3 cannot take the note it is
  /// written locally right away with the same [stamp] (hence the same id).
  Future<NoteCreateResult> _createS3Only(
    LocalNoteStore local,
    S3Config config,
    String text,
    DateTime stamp,
  ) async {
    try {
      final s3 = _s3StoreFor(config, markFailures: true);
      return (
        entry: await s3.create(text, now: stamp),
        outcome: NoteCreateOutcome.saved,
      );
    } on ArgumentError {
      // Bad input (or broken config) before anything was written: surface
      // it; there is no copy to fall back to.
      rethrow;
    } catch (e) {
      return _fallbackLocal(e, () => local.create(text, now: stamp));
    }
  }

  /// [StorageMode.both]: the trusted local copy goes first, so it is
  /// attempted even when S3 is slow or down; then S3 with the same [stamp].
  Future<NoteCreateResult> _createDual(
    LocalNoteStore local,
    S3Config config,
    String text,
    DateTime stamp,
  ) async {
    final localAttempt = await _attemptLocal(local, text, stamp);
    try {
      final s3 = _s3StoreFor(config, markFailures: true);
      final s3Entry = await s3.create(text, now: stamp);
      return switch (localAttempt) {
        // Both landed: the local entry is the canonical one.
        _LocalWritten(:final entry) => (
          entry: entry,
          outcome: NoteCreateOutcome.saved,
        ),
        // Broken local directory: the note is in the bucket. Report it, but
        // do not pretend the save failed — the note is safe, and a retry
        // would duplicate it in the bucket.
        _LocalFailed() => (
          entry: s3Entry,
          outcome: NoteCreateOutcome.savedS3Only,
        ),
      };
    } on ArgumentError {
      // The local copy already landed: report it rather than hiding a saved
      // note behind an error (a re-log would duplicate). Without one there
      // is nothing to fall back to.
      if (localAttempt case _LocalWritten(:final entry)) {
        return (entry: entry, outcome: NoteCreateOutcome.savedLocalOnly);
      }
      rethrow;
    } catch (e) {
      // Keep the local copy; if that failed too, the note is nowhere and
      // the local error surfaces.
      return _fallbackLocal(e, () async => localAttempt.entryOrRethrow());
    }
  }

  /// One local write whose failure is captured (with its stack trace)
  /// instead of thrown, so a dual write can still try S3.
  Future<_LocalAttempt> _attemptLocal(
    LocalNoteStore local,
    String text,
    DateTime stamp,
  ) async {
    try {
      return _LocalWritten(await local.create(text, now: stamp));
    } catch (error, stackTrace) {
      return _LocalFailed(error, stackTrace);
    }
  }

  /// Where a note lands when the S3 create failed with [s3Error] (not an
  /// [ArgumentError]): the local copy from [keepLocal], whose own error
  /// propagates. [S3ConfigException] means the saved settings cannot build a
  /// client — no request was sent, so no degrade window either; the outcome
  /// points at Preferences. Anything else is a transport / service failure
  /// whose degrade window the store's onFailure hook already armed.
  Future<NoteCreateResult> _fallbackLocal(
    Object s3Error,
    Future<LogEntry> Function() keepLocal,
  ) async {
    final outcome = s3Error is S3ConfigException
        ? NoteCreateOutcome.savedLocalS3SettingsInvalid
        : NoteCreateOutcome.savedLocalOnly;
    return (entry: await keepLocal(), outcome: outcome);
  }

  /// Sources for the entry browser: always local; S3 when it is part of the
  /// target (s3-only or dual, even while degraded, so remote notes appear).
  Future<BrowserNoteSources> resolveBrowserSources() async {
    bindSessionProbe();
    final local = await resolveLocal();
    final merge = _session.preferredMode.writesToS3;
    if (!merge) {
      return BrowserNoteSources(
        local: local,
        mergeWhenS3Preferred: false,
      );
    }
    // Preferred S3 with empty credentials: degrade once, list local only.
    final config = await _prefs.s3Config();
    if (!config.hasCredentials) {
      if (!_session.isDegraded) await _session.markS3Failed();
      return BrowserNoteSources(
        local: local,
        mergeWhenS3Preferred: true,
      );
    }
    final S3NoteStore s3;
    try {
      s3 = _s3StoreFor(config, markFailures: false);
    } on S3ConfigException catch (e) {
      // Saved settings that cannot build a client (malformed endpoint,
      // invalid bucket) must not blank the browser: list local notes only
      // and report why S3 is missing ([BrowserNoteSources.list] flags it).
      return BrowserNoteSources(
        local: local,
        mergeWhenS3Preferred: true,
        s3SetupError: e.message,
      );
    }
    final dualWrite = _session.preferredMode == StorageMode.both;
    return BrowserNoteSources(
      local: local,
      s3: s3,
      mergeWhenS3Preferred: true,
      preferLocalReads: dualWrite,
      keepLocalCopies: dualWrite,
    );
  }

  /// Lists notes for the browser. When S3 is preferred, merges local + S3;
  /// otherwise returns local-only rows without location badges.
  Future<List<LocatedLogEntry>> listForBrowser() async {
    final sources = await resolveBrowserSources();
    return sources.list();
  }

  Future<S3Config> loadConfig() => _prefs.s3Config();

  Future<S3NoteStore> _buildS3Store({required bool markFailures}) async {
    final config = await _prefs.s3Config();
    if (!config.hasCredentials) {
      throw StateError(
        'S3 credentials are not configured. Set access key and secret in Preferences.',
      );
    }
    return _s3StoreFor(config, markFailures: markFailures);
  }

  /// Store over a client built from the already-loaded [config]. Throws
  /// [S3ConfigException] when the settings cannot build a client.
  S3NoteStore _s3StoreFor(S3Config config, {required bool markFailures}) {
    return S3NoteStore(
      _s3ClientFactory(config),
      onFailure: markFailures ? () => _session.markS3Failed() : null,
    );
  }
}
