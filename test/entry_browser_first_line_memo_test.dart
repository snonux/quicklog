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
  Future<void> deleteObject(String key) {
    if (failNextDelete.remove(key)) {
      return Future.error(Exception('DELETE $key failed'));
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
      if (await tmp.exists()) await tmp.delete(recursive: true);
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

      await tester.pageBack();
      await pumpWithIo(tester);
      await tapAndSettle(tester, find.text('Discard'));

      expect(find.text('Entries'), findsOneWidget);
      expect(find.text('Local + S3 · alpha edited'), findsOneWidget);
    });

    testWidgets('a failed delete after a viewer edit re-reads the row', (
      tester,
    ) async {
      await start(tester);

      await tapAndSettle(tester, find.text('2026-09-01 10:00:00'));
      await tapAndSettle(tester, find.byIcon(Icons.edit_outlined));
      await saveEdit(tester, 'alpha edited');
      s3.failNextDelete.add(older);
      await tapAndSettle(tester, find.byIcon(Icons.delete_outline));
      await tapAndSettle(tester, find.widgetWithText(FilledButton, 'Delete'));

      expect(find.textContaining('Could not delete'), findsOneWidget);
      expect(find.text('Entries'), findsOneWidget);
      expect(find.text('S3 · alpha edited'), findsOneWidget);
    });

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
