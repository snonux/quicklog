import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:quicklog/screens/entry_browser_screen.dart';
import 'package:quicklog/screens/first_line_memo.dart';
import 'package:quicklog/services/active_note_store.dart';
import 'package:quicklog/services/log_service.dart';
import 'package:quicklog/services/merged_note_listing.dart';
import 'package:quicklog/services/preferences.dart';
import 'package:quicklog/services/s3_object_client.dart';
import 'package:quicklog/services/s3_session_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'io_pump.dart';

/// Fake bucket that counts GETs per key and can fail one key's next GET,
/// PUT or DELETE.
class _CountingS3 extends MemoryS3ObjectClient {
  final Map<String, int> gets = {};
  final Set<String> failNextGet = {};
  final Set<String> failNextPut = {};
  final Set<String> failNextDelete = {};

  /// Awaited when a delete is about to fail, so a test can let a frame paint
  /// while that delete is still in flight.
  Future<void> Function()? onFailingDelete;

  @override
  Future<List<int>> getObject(String key) {
    gets.update(key, (n) => n + 1, ifAbsent: () => 1);
    if (failNextGet.remove(key)) {
      return Future.error(Exception('GET $key failed'));
    }
    return super.getObject(key);
  }

  @override
  Future<void> putObject(
    String key,
    List<int> bytes, {
    String contentType = 'text/markdown',
  }) {
    if (failNextPut.remove(key)) {
      return Future.error(Exception('PUT $key failed'));
    }
    return super.putObject(key, bytes, contentType: contentType);
  }

  @override
  Future<void> deleteObject(String key) async {
    if (failNextDelete.remove(key)) {
      final hook = onFailingDelete;
      if (hook != null) await hook();
      throw Exception('DELETE $key failed');
    }
    return super.deleteObject(key);
  }
}

/// [NoteStore] whose only real member is a counting [firstLine].
class _CountingStore implements NoteStore {
  _CountingStore(this.lines);

  final Map<String, String> lines;
  final Map<String, int> calls = {};

  @override
  Future<String> firstLine(String id) async {
    calls.update(id, (n) => n + 1, ifAbsent: () => 1);
    return lines[id] ?? '';
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// [NoteStore] that hands out a fresh completer per [firstLine], so a test
/// can finish an invalidated read after its replacement has already landed.
class _QueuedStore implements NoteStore {
  final List<Completer<String>> pending = [];
  int calls = 0;

  @override
  Future<String> firstLine(String id) {
    calls++;
    final completer = Completer<String>();
    pending.add(completer);
    return completer.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// [initialData] of the subtitle [FutureBuilder] for the row showing
/// [visibleLine] (`S3 · alpha`, and so on).
String? _subtitleInitialData(WidgetTester tester, String visibleLine) {
  final tile = find.ancestor(
    of: find.text(visibleLine),
    matching: find.byType(ListTile),
  );
  return tester
      .widget<FutureBuilder<String>>(
        find.descendant(
          of: tile,
          matching: find.byType(FutureBuilder<String>),
        ),
      )
      .initialData;
}

LocatedLogEntry _located(String id, NoteStorageLocation location) =>
    LocatedLogEntry(
      entry: LogEntry(id: id, timestamp: parseLogEntryId(id)!),
      location: location,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('FirstLineMemo', () {
    const a = 'ql-260901-100000.md';
    const b = 'ql-260902-100000.md';
    late _CountingStore store;
    late FirstLineMemo memo;

    setUp(() {
      store = _CountingStore({a: 'alpha', b: 'beta'});
      memo = FirstLineMemo();
    });

    test('lookups within one generation share one read', () async {
      final row = _located(a, NoteStorageLocation.s3);
      final first = memo.firstLine(row, store, generation: 1);
      final second = memo.firstLine(row, store, generation: 1);

      expect(identical(first, second), isTrue);
      expect(await first, 'alpha');
      expect(store.calls[a], 1);
    });

    test('a new generation reads every row once more', () async {
      final rowA = _located(a, NoteStorageLocation.s3);
      final rowB = _located(b, NoteStorageLocation.s3);
      for (final generation in [1, 1, 2, 2]) {
        await memo.firstLine(rowA, store, generation: generation);
        await memo.firstLine(rowB, store, generation: generation);
      }

      expect(store.calls, {a: 2, b: 2});
    });

    test('a new location is a new key', () async {
      await memo.firstLine(
        _located(a, NoteStorageLocation.local),
        store,
        generation: 1,
      );
      await memo.firstLine(
        _located(a, NoteStorageLocation.both),
        store,
        generation: 1,
      );

      expect(store.calls[a], 2);
    });

    test('invalidate forgets only that note', () async {
      final rowA = _located(a, NoteStorageLocation.s3);
      final rowB = _located(b, NoteStorageLocation.s3);
      await memo.firstLine(rowA, store, generation: 1);
      await memo.firstLine(rowB, store, generation: 1);

      memo.invalidate(a);
      await memo.firstLine(rowA, store, generation: 1);
      await memo.firstLine(rowB, store, generation: 1);

      expect(store.calls, {a: 2, b: 1});
    });

    test('invalidate drops the note in every location', () async {
      for (final location in NoteStorageLocation.values) {
        await memo.firstLine(_located(a, location), store, generation: 1);
      }
      await memo.firstLine(
        _located(b, NoteStorageLocation.s3),
        store,
        generation: 1,
      );

      memo.invalidate(a);

      for (final location in NoteStorageLocation.values) {
        await memo.firstLine(_located(a, location), store, generation: 1);
      }
      await memo.firstLine(
        _located(b, NoteStorageLocation.s3),
        store,
        generation: 1,
      );

      expect(store.calls[a], NoteStorageLocation.values.length * 2);
      expect(store.calls[b], 1);
    });

    test('an empty read is reused until the next generation', () async {
      // firstLine collapses a failed read to ''. The memo keeps that future
      // for the load; the next generation is what retries it.
      final empty = _CountingStore({});
      final row = _located(a, NoteStorageLocation.s3);
      expect(await memo.firstLine(row, empty, generation: 1), '');
      expect(await memo.firstLine(row, empty, generation: 1), '');
      expect(empty.calls[a], 1);

      await memo.firstLine(row, empty, generation: 2);
      expect(empty.calls[a], 2);
    });

    test(
      'a cached key keeps the first future across store instances',
      () async {
        final row = _located(a, NoteStorageLocation.s3);
        await memo.firstLine(row, store, generation: 1);
        final other = _CountingStore({a: 'replaced'});
        await memo.firstLine(row, other, generation: 1);

        expect(other.calls.containsKey(a), isFalse);
      },
    );

    test('peek returns a finished line and does not read', () async {
      final row = _located(a, NoteStorageLocation.s3);
      expect(memo.peek(row, generation: 1), isNull);

      final pending = memo.firstLine(row, store, generation: 1);
      expect(memo.peek(row, generation: 1), isNull);
      expect(await pending, 'alpha');
      expect(memo.peek(row, generation: 1), 'alpha');
      expect(store.calls[a], 1);

      memo.invalidate(a);
      expect(memo.peek(row, generation: 1), isNull);

      await memo.firstLine(row, store, generation: 2);
      expect(memo.peek(row, generation: 1), isNull);
      expect(memo.peek(row, generation: 2), 'alpha');
    });

    test('remember stores a line without reading', () async {
      final row = _located(a, NoteStorageLocation.s3);
      // No load yet: this generation is not current.
      expect(memo.remember(row, 'too soon', generation: 1), isFalse);
      expect(memo.peek(row, generation: 1), isNull);
      expect(store.calls.containsKey(a), isFalse);

      await memo.firstLine(row, store, generation: 1);
      expect(store.calls[a], 1);

      expect(memo.remember(row, 'kept', generation: 1), isTrue);
      expect(memo.peek(row, generation: 1), 'kept');
      expect(await memo.firstLine(row, store, generation: 1), 'kept');
      expect(store.calls[a], 1);

      // A successful read of an empty note is stored as '', not left stale.
      expect(memo.remember(row, '', generation: 1), isTrue);
      expect(memo.peek(row, generation: 1), '');

      await memo.firstLine(row, store, generation: 2);
      expect(memo.remember(row, 'stale', generation: 1), isFalse);
      expect(memo.peek(row, generation: 2), 'alpha');
      expect(memo.peek(row, generation: 1), isNull);
      expect(store.calls[a], 2);
    });

    test(
      'a late completion after invalidate does not refill the line',
      () async {
        final queued = _QueuedStore();
        final row = _located(a, NoteStorageLocation.s3);
        final first = memo.firstLine(row, queued, generation: 1);
        memo.invalidate(a);
        final second = memo.firstLine(row, queued, generation: 1);

        queued.pending[1].complete('new');
        expect(await second, 'new');
        expect(memo.peek(row, generation: 1), 'new');

        queued.pending[0].complete('old');
        expect(await first, 'old');
        expect(memo.peek(row, generation: 1), 'new');
        expect(queued.calls, 2);
      },
    );
  });

  group('entry browser subtitles', () {
    const older = 'ql-260901-100000.md';
    const newer = 'ql-260902-100000.md';
    const local1 = 'ql-260903-100000.md';
    const local2 = 'ql-260904-100000.md';

    late Directory tmp;
    late _CountingS3 s3;
    late S3SessionController session;
    late ActiveNoteStore active;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('ql-browser-memo-');
      s3 = _CountingS3();
      await s3.putText(older, 'alpha');
      await s3.putText(newer, 'beta');
    });

    tearDown(() async {
      session.dispose();
      if (await tmp.exists()) {
        // The local-write-failure test clears a note's write bit.
        await Process.run('chmod', ['-R', 'u+rwx', tmp.path]);
        await tmp.delete(recursive: true);
      }
    });

    void writeLocal(String id, String text) =>
        File(p.join(tmp.path, id)).writeAsStringSync(text);

    /// Pumps the same browser again: its state stays, build() runs again.
    Future<void> rebuild(WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: EntryBrowserScreen(session: session, activeStore: active),
        ),
      );
      await pumpWithIo(tester);
    }

    /// Pumps the browser in storage [mode] ('s3' or 'both').
    Future<void> start(WidgetTester tester, {String mode = 's3'}) async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'flutter.Directory': tmp.path,
        'flutter.StorageMode': mode,
        'flutter.S3AccessKeyId': 'AKIA_TEST',
        'flutter.S3SecretAccessKey': 'secret_test',
      });
      final prefs = PreferencesService();
      session = S3SessionController(preferences: prefs);
      await session.load();
      active = ActiveNoteStore(
        preferences: prefs,
        session: session,
        s3ClientFactory: (_) => s3,
      );
      await rebuild(tester);
    }

    /// Taps, then lets the action's chain of file and bucket calls (and the
    /// reload after it) finish.
    Future<void> tapAndSettle(WidgetTester tester, Finder finder) async {
      await tester.tap(finder);
      await pumpWithIo(tester, rounds: 30);
    }

    /// In an open editor, replaces the text and presses Save.
    Future<void> saveEdit(WidgetTester tester, String text) async {
      await tester.enterText(find.byType(TextField), text);
      await pumpWithIo(tester);
      await tapAndSettle(tester, find.widgetWithText(FilledButton, 'Save'));
      await tester.pump(const Duration(seconds: 1));
    }

    testWidgets('rebuilds within one load reuse one GET per row', (
      tester,
    ) async {
      await start(tester);
      for (var i = 0; i < 5; i++) {
        await rebuild(tester);
      }

      expect(find.text('S3 · alpha'), findsOneWidget);
      expect(find.text('S3 · beta'), findsOneWidget);
      expect(s3.gets, {older: 1, newer: 1});
      // The resolved line is the FutureBuilder's initial data, so a row
      // scrolled back paints it on the first frame. Removing initialData
      // leaves this null.
      expect(_subtitleInitialData(tester, 'S3 · alpha'), 'alpha');
      expect(_subtitleInitialData(tester, 'S3 · beta'), 'beta');
    });

    testWidgets('each reload re-reads every row exactly once', (tester) async {
      await start(tester);

      await tapAndSettle(tester, find.byTooltip('Refresh'));
      for (var i = 0; i < 3; i++) {
        await rebuild(tester);
      }

      expect(s3.gets, {older: 2, newer: 2});
    });

    testWidgets('a reload shows a note changed elsewhere', (tester) async {
      await start(tester);
      await s3.putText(older, 'alpha from another device');

      await tapAndSettle(tester, find.byTooltip('Refresh'));

      expect(find.text('S3 · alpha from another device'), findsOneWidget);
    });

    testWidgets('a saved edit re-lists and shows the new text', (tester) async {
      await start(tester);

      // Newest row first.
      await tapAndSettle(tester, find.byIcon(Icons.edit_outlined).first);
      final beforeSave = s3.gets[newer]!; // Includes the editor's own read.
      await saveEdit(tester, 'beta edited');

      expect(find.text('Entries'), findsOneWidget);
      expect(find.text('S3 · beta edited'), findsOneWidget);
      expect(s3.gets[newer], beforeSave + 1);
      expect(s3.gets[older], 2);
    });

    testWidgets('a failed GET is retried on the next reload, not on rebuild', (
      tester,
    ) async {
      s3.failNextGet.add(older);
      await start(tester);
      await rebuild(tester);

      expect(find.text('S3 · '), findsOneWidget);
      expect(s3.gets[older], 1);

      await tapAndSettle(tester, find.byTooltip('Refresh'));

      expect(find.text('S3 · alpha'), findsOneWidget);
      expect(s3.gets[older], 2);
    });

    testWidgets('a clean back does not read again', (tester) async {
      await start(tester);
      await tapAndSettle(tester, find.byIcon(Icons.edit_outlined).first);
      expect(find.text('beta'), findsOneWidget);
      final newerBefore = s3.gets[newer]!;
      final olderBefore = s3.gets[older]!;

      await tester.pageBack();
      await pumpWithIo(tester);
      await tester.pump(const Duration(seconds: 1));

      expect(find.text('Entries'), findsOneWidget);
      expect(find.text('S3 · beta'), findsOneWidget);
      // null is "no save was attempted", so the row is not re-read. Widening
      // `saved == false` to `else` would GET this note again.
      expect(s3.gets[newer], newerBefore);
      expect(s3.gets[older], olderBefore);
    });

    testWidgets('a save that wrote one backend and failed re-reads the row', (
      tester,
    ) async {
      // Dual mode reads a 'both' note from the local copy. The S3 put fails,
      // but the local write still lands before the error is reported.
      writeLocal(older, 'alpha');
      await start(tester, mode: 'both');
      expect(find.text('Local + S3 · alpha'), findsOneWidget);

      s3.failNextPut.add(older);
      await tapAndSettle(tester, find.byIcon(Icons.edit_outlined).last);
      await saveEdit(tester, 'alpha edited');
      expect(find.textContaining('Could not save'), findsOneWidget);

      final newerBefore = s3.gets[newer];
      final olderBefore = s3.gets[older];
      await tester.pageBack();
      await pumpWithIo(tester);
      await tapAndSettle(tester, find.text('Discard'));

      expect(find.text('Entries'), findsOneWidget);
      expect(find.text('Local + S3 · alpha edited'), findsOneWidget);
      // Re-read just this row (the local copy, so no S3 GET for it). A full
      // refresh would GET the other visible row again.
      expect(s3.gets[newer], newerBefore);
      expect(s3.gets[older], olderBefore);
    });

    testWidgets(
      'revert after a partial save shows the edited local text',
      (tester) async {
        // Same partial write as above: S3 put fails, the local file lands.
        // Revert only restores the field to the pre-edit text, so leaving
        // must not be treated as a clean back.
        writeLocal(older, 'alpha');
        await start(tester, mode: 'both');
        expect(find.text('Local + S3 · alpha'), findsOneWidget);

        s3.failNextPut.add(older);
        await tapAndSettle(tester, find.byIcon(Icons.edit_outlined).last);
        await saveEdit(tester, 'alpha edited');
        expect(find.textContaining('Could not save'), findsOneWidget);

        await tester.pump(const Duration(seconds: 4));
        await tester.pump(const Duration(milliseconds: 500));
        await tester.tap(find.widgetWithText(OutlinedButton, 'Revert'));
        await pumpWithIo(tester);
        expect(find.text('alpha'), findsOneWidget);

        final newerBefore = s3.gets[newer];
        final olderBefore = s3.gets[older];
        await tester.pageBack();
        await pumpWithIo(tester, rounds: 30);
        await tester.pump(const Duration(seconds: 1));

        expect(find.text('Discard changes?'), findsNothing);
        expect(find.text('Entries'), findsOneWidget);
        expect(find.text('Local + S3 · alpha edited'), findsOneWidget);
        expect(find.text('Local + S3 · alpha'), findsNothing);
        expect(s3.gets[newer], newerBefore);
        expect(s3.gets[older], olderBefore);
      },
    );

    testWidgets(
      'a local write that fails after the S3 put keeps the local subtitle',
      (tester) async {
        // Opposite of the partial save above: the S3 put lands, the local
        // write does not. Dual-write reads local (preferLocalReads), so the
        // list shows the read-primary — the same text opening the note would
        // show.
        writeLocal(older, 'alpha');
        await start(tester, mode: 'both');
        expect(find.text('Local + S3 · alpha'), findsOneWidget);

        await tapAndSettle(tester, find.byIcon(Icons.edit_outlined).last);
        final locked = await tester.runAsync(
          () => Process.run('chmod', ['a-w', p.join(tmp.path, older)]),
        );
        expect(locked?.exitCode, 0);
        await saveEdit(tester, 'alpha from s3');
        expect(find.textContaining('Could not save'), findsOneWidget);

        final newerBefore = s3.gets[newer];
        final olderBefore = s3.gets[older];
        await tester.pageBack();
        await pumpWithIo(tester);
        await tapAndSettle(tester, find.text('Discard'));

        expect(find.text('Entries'), findsOneWidget);
        expect(find.text('Local + S3 · alpha'), findsOneWidget);
        expect(find.text('Local + S3 · alpha from s3'), findsNothing);
        // The subtitle is the local file, not an S3 GET. The other row's
        // GET count staying put is what shows this was not a full refresh.
        expect(s3.gets[newer], newerBefore);
        expect(s3.gets[older], olderBefore);
        expect(
          await tester.runAsync(
            () => File(p.join(tmp.path, older)).readAsString(),
          ),
          'alpha',
        );
        expect(utf8.decode(s3.objects[older]!), 'alpha from s3');
      },
    );

    testWidgets(
      'a discarded edit whose re-read fails keeps the old subtitle',
      (tester) async {
        await start(tester);
        expect(find.text('S3 · alpha'), findsOneWidget);

        await tapAndSettle(tester, find.byIcon(Icons.edit_outlined).last);
        s3.failNextPut.add(older);
        await tester.enterText(find.byType(TextField), 'alpha edited');
        await pumpWithIo(tester);
        await tapAndSettle(tester, find.widgetWithText(FilledButton, 'Save'));
        expect(find.textContaining('Could not save'), findsOneWidget);

        // The editor already read the note. The discard's follow-up read is
        // the one that fails; the object was never written.
        s3.failNextGet.add(older);
        final newerBefore = s3.gets[newer];
        final olderBefore = s3.gets[older];
        await tester.pageBack();
        await pumpWithIo(tester);
        await tapAndSettle(tester, find.text('Discard'));

        expect(find.text('Entries'), findsOneWidget);
        expect(find.text('S3 · alpha'), findsOneWidget);
        expect(find.text('S3 · '), findsNothing);
        expect(utf8.decode(s3.objects[older]!), 'alpha');
        expect(s3.failNextGet, isEmpty);
        expect(s3.gets[older], olderBefore! + 1);
        expect(s3.gets[newer], newerBefore);
      },
    );

    testWidgets('a failed delete after a viewer edit re-reads the row', (
      tester,
    ) async {
      await start(tester);

      await tapAndSettle(tester, find.text('2026-09-01 10:00:00'));
      await tapAndSettle(tester, find.byIcon(Icons.edit_outlined));
      await saveEdit(tester, 'alpha edited');
      s3.failNextDelete.add(older);
      // Rebuild the list while the delete is in flight, the same window the
      // route pop paints in. That frame reuses the cached line; the failure
      // then re-reads this row once.
      s3.onFailingDelete = () async {
        tester
            .element(find.byType(EntryBrowserScreen, skipOffstage: false))
            .markNeedsBuild();
        await Future<void>.delayed(const Duration(milliseconds: 80));
      };
      await tapAndSettle(tester, find.byIcon(Icons.delete_outline));
      final olderBefore = s3.gets[older]!;
      final newerBefore = s3.gets[newer]!;
      await tapAndSettle(tester, find.widgetWithText(FilledButton, 'Delete'));

      expect(find.textContaining('Could not delete'), findsOneWidget);
      expect(find.textContaining('DELETE $older failed'), findsOneWidget);
      expect(find.text('Entries'), findsOneWidget);
      expect(find.text('S3 · alpha edited'), findsOneWidget);
      // One extra GET of this row. A second invalidate while the delete is
      // in flight reads it twice; a full refresh also reads the other row.
      expect(s3.gets[older], olderBefore + 1);
      expect(s3.gets[newer], newerBefore);
    });

    testWidgets(
      'a failed delete of a both row lists the surviving S3 copy',
      (tester) async {
        writeLocal(older, 'alpha');
        await start(tester, mode: 'both');
        expect(find.text('Local + S3 · alpha'), findsOneWidget);

        s3.failNextDelete.add(older);
        await tapAndSettle(tester, find.byIcon(Icons.delete_outline).last);
        await tapAndSettle(tester, find.widgetWithText(FilledButton, 'Delete'));

        expect(find.textContaining('Could not delete'), findsOneWidget);
        expect(find.text('Local + S3 · alpha'), findsNothing);
        expect(find.text('S3 · alpha'), findsOneWidget);
        expect(find.text('S3 · '), findsNothing);
        expect(
          await fileExists(tester, File(p.join(tmp.path, older))),
          isFalse,
        );
        expect(utf8.decode(s3.objects[older]!), 'alpha');
      },
    );

    testWidgets('delete drops the row and re-reads the others once', (
      tester,
    ) async {
      await start(tester);

      await tapAndSettle(tester, find.byIcon(Icons.delete_outline).first);
      await tapAndSettle(tester, find.widgetWithText(FilledButton, 'Delete'));

      expect(find.text('S3 · beta'), findsNothing);
      expect(find.text('S3 · alpha'), findsOneWidget);
      expect(s3.gets[older], 2);
    });

    testWidgets('dual mode Copy turns a local row into Local + S3', (
      tester,
    ) async {
      writeLocal(local1, 'gamma');
      await start(tester, mode: 'both');
      expect(find.text('Local · gamma'), findsOneWidget);

      await tapAndSettle(tester, find.byTooltip('Copy to S3'));

      expect(find.text('Local · gamma'), findsNothing);
      expect(find.text('Local + S3 · gamma'), findsOneWidget);
      // Dual mode keeps reading the local copy.
      expect(s3.gets.containsKey(local1), isFalse);
    });

    testWidgets('s3 mode Move turns a local row into an S3 row', (
      tester,
    ) async {
      writeLocal(local1, 'gamma');
      await start(tester);

      await tapAndSettle(tester, find.byTooltip('Move to S3'));

      expect(find.text('Local · gamma'), findsNothing);
      expect(find.text('S3 · gamma'), findsOneWidget);
      expect(s3.gets[local1], 1);
    });

    testWidgets('Remove local copy turns a both row into an S3 row', (
      tester,
    ) async {
      writeLocal(older, 'alpha');
      await start(tester);
      expect(find.text('Local + S3 · alpha'), findsOneWidget);

      await tapAndSettle(tester, find.byTooltip('Remove local copy'));

      expect(find.text('Local + S3 · alpha'), findsNothing);
      expect(find.text('S3 · alpha'), findsOneWidget);
      expect(s3.gets[older], 2);
    });

    testWidgets('Move all turns every local row into an S3 row', (
      tester,
    ) async {
      writeLocal(local1, 'gamma');
      writeLocal(local2, 'delta');
      await start(tester);

      await tapAndSettle(tester, find.byTooltip('Move all local to S3'));

      expect(find.text('S3 · gamma'), findsOneWidget);
      expect(find.text('S3 · delta'), findsOneWidget);
      expect(s3.gets[local1], 1);
      expect(s3.gets[local2], 1);
    });

    testWidgets('a mode change re-reads the rows under the new mode', (
      tester,
    ) async {
      writeLocal(older, 'alpha local');
      await start(tester);
      // s3-only mode reads a 'both' note from S3...
      expect(find.text('Local + S3 · alpha'), findsOneWidget);

      await session.setPreferredMode(StorageMode.both);
      await pumpWithIo(tester);

      // ...dual mode from the local copy.
      expect(find.text('Local + S3 · alpha local'), findsOneWidget);
      expect(s3.gets[newer], 2);
    });

    testWidgets('local-only rows never GET from S3', (tester) async {
      writeLocal(local1, 'gamma');
      await start(tester);
      for (var i = 0; i < 3; i++) {
        await rebuild(tester);
      }

      expect(find.text('Local · gamma'), findsOneWidget);
      expect(s3.gets.containsKey(local1), isFalse);
      expect(s3.gets, {older: 1, newer: 1});
    });
  });
}
