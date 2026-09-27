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

/// Fake bucket that counts GETs per key and can fail a key's next GET.
class _CountingS3 extends MemoryS3ObjectClient {
  final Map<String, int> gets = {};
  final Set<String> failNextGet = {};

  @override
  Future<List<int>> getObject(String key) {
    gets.update(key, (n) => n + 1, ifAbsent: () => 1);
    if (failNextGet.remove(key)) {
      return Future.error(Exception('GET $key failed'));
    }
    return super.getObject(key);
  }
}

/// [NoteStore] whose only real member is a counting [firstLine].
class _CountingStore implements NoteStore {
  _CountingStore(this.lines);

  final Map<String, String> lines;
  final Map<String, int> calls = {};
  Object? throwOnce;

  @override
  Future<String> firstLine(String id) async {
    calls.update(id, (n) => n + 1, ifAbsent: () => 1);
    final error = throwOnce;
    if (error != null) {
      throwOnce = null;
      throw error;
    }
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

    test('repeated lookups share one read', () async {
      final row = _located(a, NoteStorageLocation.s3);
      final first = memo.firstLine(row, store);
      final second = memo.firstLine(row, store);

      expect(identical(first, second), isTrue);
      expect(await first, 'alpha');
      expect(await memo.firstLine(row, store), 'alpha');
      expect(store.calls[a], 1);
    });

    test('a new location is a new key', () async {
      await memo.firstLine(_located(a, NoteStorageLocation.local), store);
      await memo.firstLine(_located(a, NoteStorageLocation.both), store);

      expect(store.calls[a], 2);
    });

    test('invalidate forgets only that note', () async {
      final rowA = _located(a, NoteStorageLocation.s3);
      final rowB = _located(b, NoteStorageLocation.s3);
      await memo.firstLine(rowA, store);
      await memo.firstLine(rowB, store);

      memo.invalidate(a);
      await memo.firstLine(rowA, store);
      await memo.firstLine(rowB, store);

      expect(store.calls, {a: 2, b: 1});
    });

    test('retain keeps listed lines and drops unlisted ones', () async {
      final rowA = _located(a, NoteStorageLocation.s3);
      final rowB = _located(b, NoteStorageLocation.s3);
      await memo.firstLine(rowA, store);
      await memo.firstLine(rowB, store);

      memo.retain([rowA]);

      expect(memo.length, 1);
      await memo.firstLine(rowA, store);
      expect(store.calls[a], 1);
    });

    test('an empty line (maybe a failed read) is retried after the next '
        'listing, not before', () async {
      final row = _located(a, NoteStorageLocation.s3);
      store.lines[a] = '';
      await memo.firstLine(row, store);
      await memo.firstLine(row, store);
      expect(store.calls[a], 1);

      store.lines[a] = 'alpha';
      memo.retain([row]);

      expect(await memo.firstLine(row, store), 'alpha');
      expect(store.calls[a], 2);
    });

    test('a throwing read yields an empty line and is retried', () async {
      final row = _located(a, NoteStorageLocation.s3);
      store.throwOnce = Exception('boom');

      expect(await memo.firstLine(row, store), '');
      memo.retain([row]);

      expect(await memo.firstLine(row, store), 'alpha');
      expect(store.calls[a], 2);
    });

    test('clear forgets everything', () async {
      await memo.firstLine(_located(a, NoteStorageLocation.s3), store);
      memo.clear();

      expect(memo.length, 0);
      await memo.firstLine(_located(a, NoteStorageLocation.s3), store);
      expect(store.calls[a], 2);
    });
  });

  group('entry browser subtitles in S3 mode', () {
    const older = 'ql-260901-100000.md';
    const newer = 'ql-260902-100000.md';
    const localOnly = 'ql-260903-100000.md';

    late Directory tmp;
    late _CountingS3 s3;
    late S3SessionController session;
    late ActiveNoteStore active;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('ql-browser-memo-');
      SharedPreferences.setMockInitialValues(<String, Object>{
        'flutter.Directory': tmp.path,
        'flutter.StorageMode': 's3',
        'flutter.S3AccessKeyId': 'AKIA_TEST',
        'flutter.S3SecretAccessKey': 'secret_test',
      });
      final prefs = PreferencesService();
      session = S3SessionController(preferences: prefs);
      await session.load();
      s3 = _CountingS3();
      await s3.putText(older, 'alpha');
      await s3.putText(newer, 'beta');
      active = ActiveNoteStore(
        preferences: prefs,
        session: session,
        s3ClientFactory: (_) => s3,
      );
    });

    tearDown(() async {
      session.dispose();
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    /// Pumps the browser; calling it again rebuilds the same state.
    Future<void> pumpBrowser(WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: EntryBrowserScreen(session: session, activeStore: active),
        ),
      );
      await pumpWithIo(tester);
    }

    /// Edits the newest row (listed first) to [text] and saves.
    Future<void> editNewest(WidgetTester tester, String text) async {
      await tester.tap(find.byIcon(Icons.edit_outlined).first);
      await pumpWithIo(tester);
      await tester.enterText(find.byType(TextField), text);
      await pumpWithIo(tester);
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await pumpWithIo(tester);
      await tester.pump(const Duration(seconds: 1));
    }

    testWidgets('rebuilds reuse one GET per row', (tester) async {
      for (var i = 0; i < 5; i++) {
        await pumpBrowser(tester);
      }

      expect(find.text('S3 · alpha'), findsOneWidget);
      expect(find.text('S3 · beta'), findsOneWidget);
      expect(s3.gets, {older: 1, newer: 1});
    });

    testWidgets('a reload after an edit re-reads only the edited row', (
      tester,
    ) async {
      await pumpBrowser(tester);

      await tester.tap(find.byIcon(Icons.edit_outlined).first);
      await pumpWithIo(tester);
      // The editor's own read of the note.
      final beforeSave = s3.gets[newer]!;
      await tester.enterText(find.byType(TextField), 'beta edited');
      await pumpWithIo(tester);
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await pumpWithIo(tester);
      await tester.pump(const Duration(seconds: 1));

      expect(find.text('Entries'), findsOneWidget);
      expect(find.text('S3 · beta edited'), findsOneWidget);
      expect(s3.gets[newer], beforeSave + 1);
      expect(s3.gets[older], 1);
    });

    testWidgets('a failed GET is retried on the next reload, not on rebuild', (
      tester,
    ) async {
      s3.failNextGet.add(older);
      await pumpBrowser(tester);
      await pumpBrowser(tester);

      expect(find.text('S3 · '), findsOneWidget);
      expect(s3.gets[older], 1);

      await editNewest(tester, 'beta edited');

      expect(find.text('S3 · alpha'), findsOneWidget);
      expect(s3.gets[older], 2);
    });

    testWidgets('the Refresh button re-reads every row', (tester) async {
      await pumpBrowser(tester);

      await tester.tap(find.byTooltip('Refresh'));
      await pumpWithIo(tester);

      expect(s3.gets, {older: 2, newer: 2});
    });

    testWidgets('local-only rows never GET from S3', (tester) async {
      await tester.runAsync(
        () => File(p.join(tmp.path, localOnly)).writeAsString('gamma'),
      );
      for (var i = 0; i < 3; i++) {
        await pumpBrowser(tester);
      }

      expect(find.text('Local · gamma'), findsOneWidget);
      expect(s3.gets.containsKey(localOnly), isFalse);
      expect(s3.gets, {older: 1, newer: 1});
    });
  });
}
