import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:quicklog/services/log_service.dart';

void main() {
  group('logEntry', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('ql-test-');
    });

    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test('writes a file with ql-YYMMDD-HHMMSS.md filename pattern', () async {
      final f = await logEntry(tmp.path, 'hello');
      expect(p.basename(f.path), matches(RegExp(r'^ql-\d{6}-\d{6}\.md$')));
      expect(await f.readAsString(), 'hello');
    });

    test('preserves arbitrary content including unicode and newlines', () async {
      const text = 'line 1\nläine 2\n第三行';
      final f = await logEntry(tmp.path, text);
      expect(await f.readAsString(), text);
    });

    test('uses the provided timestamp when given', () async {
      final ts = DateTime(2026, 5, 7, 14, 30, 45);
      final f = await logEntry(tmp.path, 'x', now: ts);
      expect(p.basename(f.path), 'ql-260507-143045.md');
    });

    test('creates missing intermediate directories', () async {
      final fresh = p.join(tmp.path, 'does', 'not', 'exist');
      final f = await logEntry(fresh, 'x');
      expect(await f.readAsString(), 'x');
    });
  });

  group('listEntries', () {
    late Directory tmp;
    setUp(() async => tmp = await Directory.systemTemp.createTemp('ql-list-'));
    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test('returns entries sorted newest first and skips malformed names', () async {
      await File(p.join(tmp.path, 'ql-260101-000000.md')).writeAsString('a');
      await File(p.join(tmp.path, 'ql-260102-000000.md')).writeAsString('b');
      await File(p.join(tmp.path, 'random.md')).writeAsString('skip');
      await File(p.join(tmp.path, 'ql-bad-format.md')).writeAsString('skip');

      final entries = await listEntries(tmp.path);
      expect(entries.length, 2);
      expect(p.basename(entries[0].file.path), 'ql-260102-000000.md');
      expect(p.basename(entries[1].file.path), 'ql-260101-000000.md');
    });

    test('returns empty list for missing directory', () async {
      final entries = await listEntries(p.join(tmp.path, 'nope'));
      expect(entries, isEmpty);
    });
  });

  group('deleteEntry', () {
    late Directory tmp;
    setUp(() async => tmp = await Directory.systemTemp.createTemp('ql-del-'));
    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test('removes the file and drops it from the listing', () async {
      final f = await logEntry(tmp.path, 'bye', now: DateTime(2026, 1, 1));
      expect(await listEntries(tmp.path), hasLength(1));

      await deleteEntry(f);

      expect(await f.exists(), isFalse);
      expect(await listEntries(tmp.path), isEmpty);
    });

    test('is a no-op for an already deleted file', () async {
      final f = File(p.join(tmp.path, 'ql-260101-000000.md'));
      await expectLater(deleteEntry(f), completes);
    });

    test('leaves other entries untouched', () async {
      final keep = await logEntry(tmp.path, 'keep', now: DateTime(2026, 1, 1));
      final drop = await logEntry(tmp.path, 'drop', now: DateTime(2026, 1, 2));

      await deleteEntry(drop);

      expect(await keep.exists(), isTrue);
      expect(await listEntries(tmp.path), hasLength(1));
    });
  });

  group('entry preview helpers', () {
    late Directory tmp;
    setUp(() async => tmp = await Directory.systemTemp.createTemp('ql-prev-'));
    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test('entryFirstLine returns the first line only', () async {
      final f = await logEntry(tmp.path, 'head\ntail');
      expect(await entryFirstLine(f), 'head');
    });

    test('entryFirstLine returns empty string for unreadable files', () async {
      final missing = File(p.join(tmp.path, 'gone.md'));
      expect(await entryFirstLine(missing), '');
    });

    test('entryPreview truncates long content with an ellipsis', () async {
      final f = await logEntry(tmp.path, 'x' * 50);
      expect(await entryPreview(f, maxChars: 10), 'xxxxxxxxxx\u2026');
    });

    test('entryPreview returns short content verbatim', () async {
      final f = await logEntry(tmp.path, 'short');
      expect(await entryPreview(f, maxChars: 10), 'short');
    });
  });
}
