import 'log_service.dart';
import 's3_note_store.dart';

/// Builds the S3 store on first use (e.g. loads prefs and a client).
typedef S3NoteStoreBuilder = Future<S3NoteStore> Function();

/// Defers async prefs/client construction until the first NoteStore call.
///
/// The builder is injected, so this wrapper knows nothing about where the
/// settings come from; the built store is cached after the first success.
class LazyS3NoteStore implements NoteStore {
  LazyS3NoteStore(this._build);

  final S3NoteStoreBuilder _build;
  S3NoteStore? _inner;

  Future<S3NoteStore> _store() async {
    return _inner ??= await _build();
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
