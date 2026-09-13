import 'log_service.dart';
import 'merged_note_listing.dart';
import 'preferences.dart';
import 's3_config.dart';
import 's3_note_store.dart';
import 's3_object_client.dart';
import 's3_session_controller.dart';

typedef S3ObjectClientFactory = S3ObjectClient Function(S3Config config);

/// Local + optional S3 stores for the entry browser when S3 is preferred.
class BrowserNoteSources {
  BrowserNoteSources({
    required this.local,
    this.s3,
    required this.mergeWhenS3Preferred,
  });

  final LocalNoteStore local;
  final S3NoteStore? s3;

  /// True when preferred mode is S3 (merged listing + location badges).
  final bool mergeWhenS3Preferred;

  /// Set by [list] when an S3 LIST fails; local rows are still returned.
  bool s3ListFailed = false;

  /// Store used for read / firstLine of [located].
  /// Prefer S3 when the note lives there (including [NoteStorageLocation.both]).
  NoteStore storeFor(LocatedLogEntry located) {
    final remote = s3;
    if (located.hasS3 && remote != null) return remote;
    return local;
  }

  /// [NoteStore] for view/edit/delete that keeps [both] backends in sync on
  /// [NoteStore.update] and deletes every backend that holds the note.
  NoteStore entryStore(LocatedLogEntry located) =>
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
      throw StateError('Only notes present in both places can drop the local copy.');
    }
    await local.delete(located.id);
  }

  Future<void> moveLocalToS3(LocatedLogEntry located) async {
    final remote = s3;
    if (remote == null) {
      throw StateError('S3 is not available to receive the note.');
    }
    if (!located.isLocalOnly) {
      throw StateError('Only local-only notes can be moved to S3.');
    }
    await moveLocalNoteToS3(local: local, s3: remote, id: located.id);
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
      // Preferred S3 but no client (e.g. missing credentials): treat as list miss.
      s3ListFailed = true;
    }
    return mergeNoteLists(local: localEntries, s3: s3Entries);
  }
}

/// Routes read to the preferred backend and write/delete through
/// [BrowserNoteSources] so [NoteStorageLocation.both] stays consistent.
class _BrowserEntryStore implements NoteStore {
  _BrowserEntryStore(this._sources, this._located);

  final BrowserNoteSources _sources;
  final LocatedLogEntry _located;

  NoteStore get _primary => _sources.storeFor(_located);

  @override
  Future<LogEntry> create(String text, {DateTime? now}) =>
      throw UnsupportedError('Browser entry store does not create notes');

  @override
  Future<List<LogEntry>> list() => _primary.list();

  @override
  Future<String> read(String id) => _primary.read(id);

  @override
  Future<void> update(String id, String text) =>
      _sources.update(_located, text);

  @override
  Future<void> delete(String id) => _sources.delete(_located);

  @override
  Future<String> firstLine(String id) => _primary.firstLine(id);

  @override
  Future<String> preview(String id, {int maxChars = 200}) =>
      _primary.preview(id, maxChars: maxChars);
}

/// Resolves the process-active [NoteStore] from prefs + [S3SessionController].
///
/// Preferred S3 (and not degraded) → [S3NoteStore]; otherwise [LocalNoteStore].
/// Wires [S3SessionController.probe] for Retry and calls [markS3Failed] on
/// S3 I/O errors. The entry browser uses [resolveBrowserSources] to list both
/// backends when S3 is preferred.
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
        return _LazyS3NoteStore(this);
      },
    );
  }

  /// Local directory store (always available).
  Future<LocalNoteStore> resolveLocal() async {
    final dir = await _prefs.directory();
    return LocalNoteStore(dir);
  }

  /// Creates a new note on the preferred backend, falling back to the local
  /// store **immediately** when S3 is preferred but cannot be written, so the
  /// note lands on the first try instead of waiting for a user retry.
  ///
  /// [wentLocal] is true when the preferred mode is S3 but the note was
  /// written to the local directory (the S3 write failed, the degrade window
  /// is active, or no credentials are set). With local preferred it is false:
  /// local is the primary target, not a fallback.
  ///
  /// The fallback write uses the same timestamp (hence the same `ql-*.md`
  /// id) as the failed S3 attempt. A transport error can in theory leave a
  /// copy in the bucket (response lost) — the browser then shows the note as
  /// present in both places and the user can drop the local copy. As in
  /// plain local mode, logging twice inside one second overwrites the
  /// earlier note, because the id only has second granularity.
  ///
  /// If the local fallback write itself fails, its error is rethrown.
  Future<({LogEntry entry, bool wentLocal})> createWithFallback(
    String text, {
    DateTime? now,
  }) async {
    bindSessionProbe();
    final dir = await _prefs.directory();
    final local = LocalNoteStore(dir);
    if (_session.preferredMode != StorageMode.s3) {
      return (entry: await local.create(text, now: now), wentLocal: false);
    }
    if (!_session.shouldAttemptS3) {
      // S3 preferred but inside the degrade window: write local without
      // spending a network timeout on every note.
      return (entry: await local.create(text, now: now), wentLocal: true);
    }
    final config = await _prefs.s3Config();
    if (!config.hasCredentials) {
      await _session.markS3Failed();
      return (entry: await local.create(text, now: now), wentLocal: true);
    }
    final stamp = now ?? DateTime.now();
    try {
      final s3 = await _buildS3Store(markFailures: true);
      return (entry: await s3.create(text, now: stamp), wentLocal: false);
    } on ArgumentError {
      // Bad input, not a transport failure: do not paper over it with a
      // local copy.
      rethrow;
    } catch (_) {
      // S3 transport / service failure: the store's onFailure hook already
      // armed the degrade window. Write the note to the local directory now,
      // with the same stamp, so nothing is lost on the first try.
      return (entry: await local.create(text, now: stamp), wentLocal: true);
    }
  }

  /// Sources for the entry browser: always local; S3 when preferred and
  /// credentials exist (even while degraded, so remote notes still appear).
  Future<BrowserNoteSources> resolveBrowserSources() async {
    bindSessionProbe();
    final local = await resolveLocal();
    final merge = _session.preferredMode == StorageMode.s3;
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
    final s3 = await _buildS3Store(markFailures: false);
    return BrowserNoteSources(
      local: local,
      s3: s3,
      mergeWhenS3Preferred: true,
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
    final client = _s3ClientFactory(config);
    return S3NoteStore(
      client,
      onFailure: markFailures ? () => _session.markS3Failed() : null,
    );
  }
}

/// Defers async prefs/client construction until the first NoteStore call.
class _LazyS3NoteStore implements NoteStore {
  _LazyS3NoteStore(this._active);

  final ActiveNoteStore _active;
  S3NoteStore? _inner;

  Future<S3NoteStore> _store() async {
    return _inner ??= await _active._buildS3Store(markFailures: true);
  }

  @override
  Future<LogEntry> create(String text, {DateTime? now}) async =>
      (await _store()).create(text, now: now);

  @override
  Future<List<LogEntry>> list() async => (await _store()).list();

  @override
  Future<String> read(String id) async => (await _store()).read(id);

  @override
  Future<void> update(String id, String text) async =>
      (await _store()).update(id, text);

  @override
  Future<void> delete(String id) async => (await _store()).delete(id);

  @override
  Future<String> firstLine(String id) async => (await _store()).firstLine(id);

  @override
  Future<String> preview(String id, {int maxChars = 200}) async =>
      (await _store()).preview(id, maxChars: maxChars);
}
