import 'log_service.dart';
import 'preferences.dart';
import 's3_config.dart';
import 's3_note_store.dart';
import 's3_object_client.dart';
import 's3_session_controller.dart';

typedef S3ObjectClientFactory = S3ObjectClient Function(S3Config config);

/// Resolves the process-active [NoteStore] from prefs + [S3SessionController].
///
/// Preferred S3 (and not degraded) → [S3NoteStore]; otherwise [LocalNoteStore].
/// Wires [S3SessionController.probe] for Retry and calls [markS3Failed] on
/// S3 I/O errors.
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
