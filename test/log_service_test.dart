import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:quicklog/services/log_service.dart';

void main() {
  group('LocalNoteStore.create', () {
    late Directory tmp;
    late LocalNoteStore store;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('ql-test-');
      store = LocalNoteStore(tmp.path);
    });

    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test('writes a file with ql-YYMMDD-HHMMSS.md filename pattern', () async {
      final entry = await store.create('hello');
      expect(entry.id, matches(RegExp(r'^ql-\d{6}-\d{6}\.md$')));
      expect(await store.read(entry.id), 'hello');
      expect(await File(p.join(tmp.path, entry.id)).exists(), isTrue);
    });

    test('preserves arbitrary content including unicode and newlines', () async {
      const text = 'line 1\nläine 2\n第三行';
      final entry = await store.create(text);
      expect(await store.read(entry.id), text);
    });

    test('uses the provided timestamp when given', () async {
      final ts = DateTime(2026, 5, 7, 14, 30, 45);
      final entry = await store.create('x', now: ts);
      expect(entry.id, 'ql-260507-143045.md');
      expect(entry.timestamp, ts);
    });

    test('creates missing intermediate directories', () async {
      final fresh = p.join(tmp.path, 'does', 'not', 'exist');
      final nested = LocalNoteStore(fresh);
      final entry = await nested.create('x');
      expect(await nested.read(entry.id), 'x');
    });
  });

  group('LocalNoteStore.list', () {
    late Directory tmp;
    late LocalNoteStore store;
    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('ql-list-');
      store = LocalNoteStore(tmp.path);
    });
    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test('returns entries sorted newest first and skips malformed names', () async {
      await File(p.join(tmp.path, 'ql-260101-000000.md')).writeAsString('a');
      await File(p.join(tmp.path, 'ql-260102-000000.md')).writeAsString('b');
      await File(p.join(tmp.path, 'random.md')).writeAsString('skip');
      await File(p.join(tmp.path, 'ql-bad-format.md')).writeAsString('skip');

      final entries = await store.list();
      expect(entries.length, 2);
      expect(entries[0].id, 'ql-260102-000000.md');
      expect(entries[1].id, 'ql-260101-000000.md');
    });

    test('returns empty list for missing directory', () async {
      final entries = await LocalNoteStore(p.join(tmp.path, 'nope')).list();
      expect(entries, isEmpty);
    });
  });

  group('LocalNoteStore.delete', () {
    late Directory tmp;
    late LocalNoteStore store;
    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('ql-del-');
      store = LocalNoteStore(tmp.path);
    });
    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test('removes the file and drops it from the listing', () async {
      final entry = await store.create('bye', now: DateTime(2026, 1, 1));
      expect(await store.list(), hasLength(1));

      await store.delete(entry.id);

      expect(await File(p.join(tmp.path, entry.id)).exists(), isFalse);
      expect(await store.list(), isEmpty);
    });

    test('is a no-op for an already deleted file', () async {
      await expectLater(store.delete('ql-260101-000000.md'), completes);
    });

    test('leaves other entries untouched', () async {
      final keep = await store.create('keep', now: DateTime(2026, 1, 1));
      final drop = await store.create('drop', now: DateTime(2026, 1, 2));

      await store.delete(drop.id);

      expect(await File(p.join(tmp.path, keep.id)).exists(), isTrue);
      expect(await store.list(), hasLength(1));
    });
  });

  group('LocalNoteStore preview helpers', () {
    late Directory tmp;
    late LocalNoteStore store;
    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('ql-prev-');
      store = LocalNoteStore(tmp.path);
    });
    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test('firstLine returns the first line only', () async {
      final entry = await store.create('head\ntail');
      expect(await store.firstLine(entry.id), 'head');
    });

    test('firstLine returns empty string for unreadable files', () async {
      expect(await store.firstLine('gone.md'), '');
    });

    test('preview truncates long content with an ellipsis', () async {
      final entry = await store.create('x' * 50);
      expect(await store.preview(entry.id, maxChars: 10), 'xxxxxxxxxx\u2026');
    });

    test('preview returns short content verbatim', () async {
      final entry = await store.create('short');
      expect(await store.preview(entry.id, maxChars: 10), 'short');
    });

    test('firstLineOf and previewOf are pure string helpers', () {
      expect(firstLineOf('a\nb'), 'a');
      expect(previewOf('abcdefghij', maxChars: 4), 'abcd\u2026');
    });
  });

  group('LocalNoteStore editing', () {
    late Directory tmp;
    late LocalNoteStore store;
    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('ql-edit-');
      store = LocalNoteStore(tmp.path);
    });
    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test('read returns the full text', () async {
      final entry = await store.create('head\ntail');
      expect(await store.read(entry.id), 'head\ntail');
    });

    test('read throws for unreadable files', () async {
      expect(store.read('gone.md'), throwsA(isA<FileSystemException>()));
    });

    test('update rewrites the same file', () async {
      final entry = await store.create('before');
      await store.update(entry.id, 'after');
      expect(await store.read(entry.id), 'after');
      // The filename carries the creation time, so editing must not add a
      // second file for the same note.
      expect((await store.list()).length, 1);
    });
  });
}
