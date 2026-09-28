import 'dart:io';

import 'package:flutter/services.dart';

import 'log_service.dart';

/// Notes inside an Android document tree whose read/write grant was persisted
/// when the user selected it. The URI is an opaque provider identifier, never
/// a filesystem path. Missing or revoked grants fail visibly, including list.
class SafNoteStore implements NoteStore {
  SafNoteStore(this.treeUri, {MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('org.buetow.quicklog/saf') {
    if (treeUri.isEmpty) throw ArgumentError.value(treeUri, 'treeUri');
  }

  final String treeUri;
  final MethodChannel _channel;

  Map<String, String> _args({String? id, String? text}) {
    final args = <String, String>{'treeUri': treeUri};
    if (id != null) {
      args['id'] = id;
    }
    if (text != null) {
      args['text'] = text;
    }
    return args;
  }

  void _requireId(String id) {
    if (parseLogEntryId(id) == null) {
      throw ArgumentError.value(id, 'id', 'must match ql-YYMMDD-HHmmss.md');
    }
  }

  @override
  Future<LogEntry> create(String text, {DateTime? now}) async {
    final id = logEntryIdFor(now ?? DateTime.now());
    await _channel.invokeMethod<void>('create', _args(id: id, text: text));
    return LogEntry(id: id, timestamp: parseLogEntryId(id)!);
  }

  @override
  Future<List<LogEntry>> list() async {
    final names = await _channel.invokeListMethod<String>('list', _args());
    if (names == null) {
      throw StateError('The document provider returned no listing.');
    }
    final entries = <LogEntry>[];
    final seen = <String>{};
    for (final name in names) {
      final timestamp = parseLogEntryId(name);
      if (timestamp != null) {
        if (!seen.add(name)) {
          throw StateError(
            'The document provider returned duplicate note $name.',
          );
        }
        entries.add(LogEntry(id: name, timestamp: timestamp));
      }
    }
    entries.sort((a, b) => b.timestamp.compareTo(a.timestamp));
    return entries;
  }

  @override
  Future<String> read(String id) async {
    _requireId(id);
    final String? text;
    try {
      text = await _channel.invokeMethod<String>('read', _args(id: id));
    } on PlatformException catch (e) {
      if (e.code == 'not_found') {
        throw PathNotFoundException(id, const OSError('Note not found'));
      }
      rethrow;
    }
    if (text == null) {
      throw StateError('The document provider returned no note.');
    }
    return text;
  }

  @override
  Future<void> update(String id, String text) async {
    _requireId(id);
    await _channel.invokeMethod<void>('update', _args(id: id, text: text));
  }

  @override
  Future<void> delete(String id) async {
    _requireId(id);
    await _channel.invokeMethod<void>('delete', _args(id: id));
  }

  @override
  Future<String> firstLine(String id) async {
    try {
      _requireId(id);
      final line = await _channel.invokeMethod<String>(
        'firstLine',
        _args(id: id),
      );
      if (line == null) {
        throw StateError('The document provider returned no note.');
      }
      return line;
    } catch (_) {
      return '';
    }
  }

  @override
  Future<String> preview(String id, {int maxChars = 200}) async =>
      previewOf(await read(id), maxChars: maxChars);
}
