import 'dart:async';

import 'browser_note_sources.dart';
import 'dual_write_s3_repair.dart';
import 'lazy_s3_note_store.dart';
import 'log_service.dart';
import 'merged_note_listing.dart';
import 'preferences.dart';
import 's3_config.dart';
import 's3_note_store.dart';
import 's3_object_client.dart';
import 's3_session_controller.dart';
import 'saf_note_store.dart';

typedef _NoteScope = ({String folderKey, String id});

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

class _BusyFallback {
  _BusyFallback(
    this.text,
    this.config,
    this.saved,
    this.revision,
    this.folderKey,
  );
  final String text;
  final S3Config config;
  final Future<LogEntry> saved;
  final int revision;
  final String folderKey;
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
    NoteStore Function(String uri)? safStoreFactory,
  }) : this._(
         preferences ?? PreferencesService(),
         session ?? S3SessionController.instance,
         s3ClientFactory ?? _defaultMinioFactory,
         safStoreFactory ?? SafNoteStore.new,
       );

  ActiveNoteStore._(
    this._prefs,
    this._session,
    this._s3ClientFactory,
    this._safStoreFactory,
  ) : _repairs = DualWriteS3Repair(preferences: _prefs);

  static final ActiveNoteStore instance = ActiveNoteStore();

  final PreferencesService _prefs;
  final S3SessionController _session;
  final S3ObjectClientFactory _s3ClientFactory;
  final NoteStore Function(String uri) _safStoreFactory;
  final DualWriteS3Repair _repairs;
  bool _probeBound = false;
  Future<void>? _s3OnlyReplay;
  Future<void> _s3OnlyWriteChain = Future<void>.value();
  int _s3OnlyWritesPending = 0;
  final Map<_NoteScope, _BusyFallback> _busyFallbacks = {};
  int _noteIntentRevision = 0;
  final Map<_NoteScope, int> _acknowledgedNoteRevisions = {};

  void _acknowledgeNote(String id, int revision, {required String folderKey}) {
    final scope = (folderKey: folderKey, id: id);
    if ((_acknowledgedNoteRevisions[scope] ?? 0) < revision) {
      _acknowledgedNoteRevisions[scope] = revision;
    }
    final earlier = _busyFallbacks[scope];
    if (earlier != null &&
        earlier.revision < _acknowledgedNoteRevisions[scope]!) {
      // Every acknowledged save supersedes older captured text, regardless
      // of mode/config branch. Keep its durable repair until a PUT succeeds.
      _busyFallbacks.remove(scope);
    }
  }

  bool _isCurrentS3Fallback(_NoteScope scope, _BusyFallback fallback) =>
      identical(_busyFallbacks[scope], fallback) &&
      (_acknowledgedNoteRevisions[scope] ?? 0) <= fallback.revision &&
      _session.preferredMode == StorageMode.s3;

  /// Serialize creates with each recovery existence-check/PUT pair. Local
  /// listing and reads stay outside this queue, and each note releases it.
  Future<T> _serializeS3OnlyWrite<T>(Future<T> Function() action) {
    _s3OnlyWritesPending++;
    final result = _s3OnlyWriteChain.then((_) => action());
    final finalized = result
        .then(
          (_) => _reconcileBusyFallbacks(),
          onError: (Object _, StackTrace _) => _reconcileBusyFallbacks(),
        )
        .whenComplete(() {
          _s3OnlyWritesPending--;
        });
    _s3OnlyWriteChain = finalized.then(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  Future<void> _reconcileBusyFallbacks() async {
    final attempted = <_BusyFallback>{};
    while (_session.preferredMode == StorageMode.s3) {
      final pending = _busyFallbacks.entries
          .where((e) => !attempted.contains(e.value))
          .toList();
      if (pending.isEmpty) return;
      for (final item in pending) {
        final fallback = item.value;
        attempted.add(fallback);
        try {
          await fallback.saved;
          if (!_isCurrentS3Fallback(item.key, fallback)) {
            continue;
          }
          final s3 = _s3StoreFor(fallback.config, markFailures: false);
          String? remoteText;
          try {
            remoteText = await s3.read(item.key.id);
          } catch (error) {
            if (!isMissingObjectError(error)) rethrow;
          }
          if (!_isCurrentS3Fallback(item.key, fallback)) {
            continue;
          }
          if (remoteText != fallback.text) {
            await s3.update(item.key.id, fallback.text);
          }
          if (!_isCurrentS3Fallback(item.key, fallback)) continue;
          await _repairs.clear(item.key.id, folderKey: fallback.folderKey);
          if (_isCurrentS3Fallback(item.key, fallback)) {
            _busyFallbacks.remove(item.key);
          }
        } catch (_) {
          // The acknowledged local write and durable repair remain safe.
        }
      }
    }
  }

  Future<bool> _preserveBusyLocal(String id, String folderKey) async {
    final scope = (folderKey: folderKey, id: id);
    while (true) {
      final fallback = _busyFallbacks[scope];
      if (fallback == null) return false;
      try {
        await fallback.saved;
      } catch (_) {
        return false;
      }
      if (identical(_busyFallbacks[scope], fallback)) return true;
    }
  }

  Future<void> _runS3OnlyBrowserMutation(
    String id,
    Future<void> Function() action,
    String folderKey,
  ) {
    final scope = (folderKey: folderKey, id: id);
    final earlierFallback = _busyFallbacks[scope];
    return _serializeS3OnlyWrite(() async {
      if (identical(_busyFallbacks[scope], earlierFallback)) {
        _busyFallbacks.remove(scope);
        await _repairs.clear(id, folderKey: folderKey);
      }
      await action();
    });
  }

  S3SessionController get session => _session;

  static S3ObjectClient _defaultMinioFactory(S3Config config) =>
      MinioS3ObjectClient(config);

  /// Bind a LIST probe and recovery hook once (idempotent). Call before
  /// [S3SessionController.load] so cold-start expiry can replay local notes.
  void bindSessionProbe() {
    if (_probeBound) return;
    _probeBound = true;
    _session.probe = () async {
      final store = await _buildS3Store(markFailures: true);
      await store.probe();
    };
    _session.onRecovered = () {
      if (_session.preferredMode == StorageMode.s3) {
        return replayS3OnlyLocalNotes();
      }
      return replayDualWriteRepairs();
    };
  }

  /// On S3-only recovery, copy every local note absent from the bucket.
  /// A failed replay must not turn a successful probe or new save into a
  /// failure. Local files remain available; keys found in the bucket are
  /// skipped (the client cannot make the check and PUT atomic).
  Future<void> replayS3OnlyLocalNotes() {
    return _s3OnlyReplay ??= _replayS3OnlyLocalNotes().whenComplete(() {
      _s3OnlyReplay = null;
    });
  }

  Future<void> _replayS3OnlyLocalNotes() async {
    if (_session.preferredMode != StorageMode.s3 || !_session.shouldAttemptS3) {
      return;
    }
    try {
      final location = await _resolveLocalWithKey();
      final local = location.store;
      final folderKey = location.key;
      final localEntries = await local.list();
      if (localEntries.isEmpty) return;
      final s3 = await _buildS3Store(markFailures: false);
      if (await _repairs.hasPending()) {
        final uploads =
            (await _prefs.dualWritePendingFolders())[folderKey]?.uploads ??
            <String>[];
        for (final id in uploads) {
          final scope = (folderKey: folderKey, id: id);
          try {
            await _serializeS3OnlyWrite(() async {
              final earlierFallback = _busyFallbacks[scope];
              final revision = _acknowledgedNoteRevisions[scope];
              final text = await local.read(id);
              if (_session.preferredMode != StorageMode.s3) return;
              await s3.update(id, text);
              if (identical(_busyFallbacks[scope], earlierFallback) &&
                  _acknowledgedNoteRevisions[scope] == revision) {
                await _repairs.clear(id, folderKey: folderKey);
              }
            });
          } catch (_) {
            // Network I/O must not hold the persistence queue: new local
            // fallbacks need to become durable before acknowledgment.
          }
        }
      }
      final remoteEntries = await s3.list();
      await uploadMissingLocalNotes(
        local: local,
        s3: s3,
        localEntries: localEntries,
        s3Entries: remoteEntries,
        shouldContinue: () => _session.preferredMode == StorageMode.s3,
        writeMissing: (id, text) => _serializeS3OnlyWrite(() {
          if (_session.preferredMode != StorageMode.s3) {
            return Future<bool>.value(false);
          }
          return copyTextToS3IfMissing(
            s3: s3,
            id: id,
            text: text,
            readCurrentText: () => local.read(id),
            shouldContinue: () => _session.preferredMode == StorageMode.s3,
          );
        }),
      );
    } catch (_) {
      // Nothing is removed locally; another successful attempt retries.
    } finally {
      await _s3OnlyWriteChain;
    }
  }

  /// Replays dual-write repairs once, when the preferred mode is dual-write
  /// and S3 is not inside the degrade window. No-op in s3-only and local
  /// mode, and when nothing is queued. Wired to
  /// [S3SessionController.onRecovered].
  Future<void> replayDualWriteRepairs() async {
    if (_session.preferredMode != StorageMode.both) return;
    if (!_session.shouldAttemptS3) return;
    if (!await _repairs.hasPending()) return;
    final config = await _prefs.s3Config();
    if (!config.hasCredentials) return;
    final S3NoteStore s3;
    try {
      s3 = _s3StoreFor(config, markFailures: false);
    } on S3ConfigException {
      return;
    }
    await _repairs.replay(local: await resolveLocal(), s3: s3);
  }

  /// Active store for create/list/read/update/delete.
  Future<NoteStore> resolve() async {
    bindSessionProbe();
    final local = await resolveLocal();
    if (_session.preferredMode == StorageMode.both) {
      // Dual write: reads prefer the local copy (present for notes created
      // in this mode); new notes go through createNote, which writes both.
      return local;
    }
    if (_session.shouldAttemptS3) {
      final config = await _prefs.s3Config();
      if (!config.hasCredentials) {
        // Preferred S3 but nothing to authenticate with: fall back to local
        // and arm degrade so the banner / retry path stay consistent.
        await _session.markS3Failed();
        return local;
      }
    }
    return _session.resolveStore(
      local: () => local,
      s3: () {
        // resolveStore expects a sync factory; build from last-known config
        // via a thin deferred wrapper that loads prefs on first use.
        return LazyS3NoteStore(() => _buildS3Store(markFailures: true));
      },
    );
  }

  /// Selected local store. A revoked SAF grant stays selected and fails
  /// visibly; silently writing to the old path could lose notes.
  Future<NoteStore> resolveLocal() async =>
      (await _resolveLocalWithKey()).store;

  Future<({NoteStore store, String key})> _resolveLocalWithKey() async {
    final folder = await _prefs.scopedFolder();
    if (folder != null) {
      return (store: _safStoreFactory(folder.uri), key: 'saf:${folder.uri}');
    }
    final directory = await _prefs.directory();
    return (store: LocalNoteStore(directory), key: directory);
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
    final stamp = now ?? DateTime.now();
    final revision = ++_noteIntentRevision;
    bindSessionProbe();
    final location = await _resolveLocalWithKey();
    final result = await _createNote(
      text,
      stamp,
      revision,
      location.store,
      location.key,
    );
    final id = result.entry.id;
    _acknowledgeNote(id, revision, folderKey: location.key);
    return result;
  }

  Future<NoteCreateResult> _createNote(
    String text,
    DateTime stamp,
    int revision,
    NoteStore local,
    String folderKey,
  ) async {
    if (_session.preferredMode == StorageMode.local) {
      return _createLocal(local, text, stamp, NoteCreateOutcome.saved);
    }
    final config = await _s3ConfigForCreate();
    if (config == null) {
      if (_session.preferredMode == StorageMode.s3 &&
          _s3OnlyWritesPending > 0) {
        return _createBusyS3Fallback(
          local,
          await _prefs.s3Config(),
          text,
          stamp,
          revision,
          folderKey,
        );
      }
      return _createLocal(local, text, stamp, NoteCreateOutcome.savedLocalOnly);
    }
    return _session.preferredMode == StorageMode.both
        ? _createDual(local, config, text, stamp)
        : _createS3Only(local, config, text, stamp, revision, folderKey);
  }

  /// Writes the note to the local directory only and reports [outcome].
  Future<NoteCreateResult> _createLocal(
    NoteStore local,
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
  Future<NoteCreateResult> _createBusyS3Fallback(
    NoteStore local,
    S3Config config,
    String text,
    DateTime stamp,
    int revision,
    String folderKey,
  ) async {
    final id = logEntryIdFor(stamp);
    final scope = (folderKey: folderKey, id: id);
    final saved = () async {
      final entry = await local.create(text, now: stamp);
      await _repairs.enqueueUpload(entry.id, folderKey: folderKey);
      _acknowledgeNote(id, revision, folderKey: folderKey);
      return entry;
    }();
    final fallback = _BusyFallback(text, config, saved, revision, folderKey);
    _busyFallbacks[scope] = fallback;
    try {
      return (entry: await saved, outcome: NoteCreateOutcome.savedLocalOnly);
    } catch (_) {
      if (identical(_busyFallbacks[scope], fallback)) {
        _busyFallbacks.remove(scope);
      }
      rethrow;
    }
  }

  Future<NoteCreateResult> _createS3Only(
    NoteStore local,
    S3Config config,
    String text,
    DateTime stamp,
    int revision,
    String folderKey,
  ) async {
    final id = logEntryIdFor(stamp);
    final scope = (folderKey: folderKey, id: id);
    if (_s3OnlyWritesPending > 0) {
      return _createBusyS3Fallback(
        local,
        config,
        text,
        stamp,
        revision,
        folderKey,
      );
    }
    try {
      final s3 = _s3StoreFor(config, markFailures: true);
      final entry = await _serializeS3OnlyWrite(() async {
        final olderFallback = _busyFallbacks[scope];
        if (olderFallback != null && olderFallback.revision < revision) {
          // The new intent supersedes this in-memory repair. Its durable
          // queue remains until PUT succeeds, preserving recovery on error.
          _busyFallbacks.remove(scope);
        }
        final entry = await s3.create(text, now: stamp);
        final newerFallback = _busyFallbacks[scope];
        if ((newerFallback == null || newerFallback.revision <= revision) &&
            (_acknowledgedNoteRevisions[scope] ?? 0) <= revision) {
          await _repairs.clear(id, folderKey: folderKey);
        }
        return entry;
      });
      unawaited(replayS3OnlyLocalNotes());
      return (entry: entry, outcome: NoteCreateOutcome.saved);
    } on ArgumentError {
      // Bad input (or broken config) before anything was written: surface
      // it; there is no copy to fall back to.
      rethrow;
    } catch (e) {
      return _fallbackLocal(e, () {
        if ((_acknowledgedNoteRevisions[scope] ?? 0) > revision) {
          // A newer same-id local save was already acknowledged while this
          // older request failed. Never replace its durable text with ours.
          return Future.value(
            LogEntry(id: id, timestamp: parseLogEntryId(id)!),
          );
        }
        return local.create(text, now: stamp);
      });
    }
  }

  /// [StorageMode.both]: the trusted local copy goes first, so it is
  /// attempted even when S3 is slow or down; then S3 with the same [stamp].
  Future<NoteCreateResult> _createDual(
    NoteStore local,
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
    NoteStore local,
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
    final location = await _resolveLocalWithKey();
    final local = location.store;
    final folderKey = location.key;
    final merge = _session.preferredMode.writesToS3;
    if (!merge) {
      return BrowserNoteSources(local: local, mergeWhenS3Preferred: false);
    }
    // Preferred S3 with empty credentials: degrade once, list local only.
    final config = await _prefs.s3Config();
    if (!config.hasCredentials) {
      if (!_session.isDegraded) await _session.markS3Failed();
      return BrowserNoteSources(local: local, mergeWhenS3Preferred: true);
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
      pendingRepairs: dualWrite ? _repairs : null,
      runMutation: dualWrite
          ? null
          : (id, action) => _runS3OnlyBrowserMutation(id, action, folderKey),
      preserveNewerLocal: dualWrite
          ? null
          : (id) => _preserveBusyLocal(id, folderKey),
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
