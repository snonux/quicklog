import 'log_service.dart';

/// One existing note.
///
/// View, edit, and delete screens take this instead of a [NoteStore]. A
/// [NoteStore] can create notes and its update/delete take an id, which the
/// browser's per-entry store used to ignore while still claiming to be a
/// [NoteStore] (and throwing from [NoteStore.create]).
abstract class EntryHandle {
  LogEntry get entry;

  String get id => entry.id;

  Future<String> read();

  Future<void> update(String text);

  Future<void> delete();

  /// First line, or '' when the note cannot be read.
  Future<String> firstLine();

  /// Leading text. Unlike [firstLine], read errors propagate.
  Future<String> preview({int maxChars = 200});
}

/// Binds [store] to [entry]. For a note that lives in one store. A note in
/// both places uses the browser's own handle, which writes every backend.
class BoundNoteStore implements EntryHandle {
  BoundNoteStore(this._store, this.entry);

  final NoteStore _store;

  @override
  final LogEntry entry;

  @override
  String get id => entry.id;

  @override
  Future<String> read() => _store.read(id);

  @override
  Future<void> update(String text) => _store.update(id, text);

  @override
  Future<void> delete() => _store.delete(id);

  @override
  Future<String> firstLine() => _store.firstLine(id);

  @override
  Future<String> preview({int maxChars = 200}) =>
      _store.preview(id, maxChars: maxChars);
}
