import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:quicklog/screens/entry_browser_screen.dart';
import 'package:quicklog/screens/preferences_screen.dart';
import 'package:quicklog/services/active_note_store.dart';
import 'package:quicklog/services/log_service.dart';
import 'package:quicklog/services/merged_note_listing.dart';
import 'package:quicklog/services/preferences.dart';
import 'package:quicklog/services/s3_config.dart';
import 'package:quicklog/services/s3_object_client.dart';
import 'package:quicklog/services/s3_session_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'io_pump.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late PreferencesService prefs;
  late S3SessionController session;
  late MemoryS3ObjectClient fakeS3;
  late ActiveNoteStore active;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('ql-s3-ui-');
    SharedPreferences.setMockInitialValues(<String, Object>{
      'flutter.Directory': tmp.path,
      'flutter.S3AccessKeyId': 'AKIA_TEST',
      'flutter.S3SecretAccessKey': 'secret_test',
    });
    prefs = PreferencesService();
    session = S3SessionController(preferences: prefs);
    await session.load();
    fakeS3 = MemoryS3ObjectClient();
    active = ActiveNoteStore(
      preferences: prefs,
      session: session,
      s3ClientFactory: (_) => fakeS3,
    );
    active.bindSessionProbe();
  });

  tearDown(() async {
    session.dispose();
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  testWidgets('preferences shows S3 fields when S3 mode selected',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: PreferencesScreen(session: session, activeStore: active),
      ),
    );
    await pumpWithIo(tester);

    expect(find.text('S3 endpoint:'), findsNothing);

    await tester.tap(find.text('S3 only'));
    await tester.pump();

    expect(find.text('S3 endpoint:'), findsOneWidget);
    expect(find.text('Region:'), findsOneWidget);
    expect(find.text('Bucket:'), findsOneWidget);

    // Dual mode shows the same S3 configuration fields and its own helper.
    await tester.tap(find.text('Local + S3'));
    await tester.pump();

    expect(find.text('S3 endpoint:'), findsOneWidget);
    expect(find.text('Access key ID:'), findsNothing);
    expect(
      find.textContaining('Every note is written to this directory and to S3'),
      findsOneWidget,
    );

    // Back to S3 only for the credential-field checks below.
    await tester.tap(find.text('S3 only'));
    await tester.pump();

    // ListView builds lazily; scroll to reveal credential fields.
    await tester.drag(find.byType(ListView), const Offset(0, -400));
    await tester.pump();

    expect(find.text('Access key ID:'), findsOneWidget);
    expect(find.text('Secret access key:'), findsOneWidget);
    expect(find.text('Test connection'), findsOneWidget);
  });

  testWidgets('browser lists and opens entries from fake-S3 store',
      (tester) async {
    await session.setPreferredMode(StorageMode.s3);
    await prefs.setS3Config(
      S3Config(
        endpoint: kDefaultS3Endpoint,
        region: kDefaultS3Region,
        bucket: kDefaultS3Bucket,
        accessKeyId: 'AKIA_TEST',
        secretAccessKey: 'secret_test',
      ),
    );
    final store = await active.resolve();
    final entry = await store.create(
      'from s3\nsecond line',
      now: DateTime(2026, 9, 8, 9, 0, 0),
    );
    expect(fakeS3.objects.containsKey(entry.id), isTrue);

    await tester.pumpWidget(
      MaterialApp(
        home: EntryBrowserScreen(session: session, activeStore: active),
      ),
    );
    await pumpWithIo(tester);

    expect(find.textContaining('from s3'), findsWidgets);

    await tester.tap(find.textContaining('from s3').first);
    await pumpWithIo(tester);

    expect(find.text('from s3\nsecond line'), findsOneWidget);
  });

  test('ActiveNoteStore falls back to local when degraded', () async {
    await session.setPreferredMode(StorageMode.s3);
    await session.markS3Failed();
    fakeS3.alwaysFail = Exception('should not be called');

    final resolved = await active.resolve();
    final entry = await resolved.create(
      'local fallback',
      now: DateTime(2026, 9, 8, 8, 0, 0),
    );
    expect(File(p.join(tmp.path, entry.id)).existsSync(), isTrue);
    expect(fakeS3.objects, isEmpty);
  });

  test('createNote saves to S3 when reachable', () async {
    await session.setPreferredMode(StorageMode.s3);
    await prefs.setS3Config(
      S3Config(
        endpoint: kDefaultS3Endpoint,
        region: kDefaultS3Region,
        bucket: kDefaultS3Bucket,
        accessKeyId: 'AKIA_TEST',
        secretAccessKey: 'secret_test',
      ),
    );

    final result = await active.createNote(
      'to s3',
      now: DateTime(2026, 9, 8, 12, 0, 0),
    );

    expect(result.outcome, NoteCreateOutcome.saved);
    expect(result.entry.id, 'ql-260908-120000.md');
    expect(fakeS3.objects.containsKey('ql-260908-120000.md'), isTrue);
    expect(session.isDegraded, isFalse);
  });

  test('createNote writes locally on first try when S3 fails',
      () async {
    await session.setPreferredMode(StorageMode.s3);
    await prefs.setS3Config(
      S3Config(
        endpoint: kDefaultS3Endpoint,
        region: kDefaultS3Region,
        bucket: kDefaultS3Bucket,
        accessKeyId: 'AKIA_TEST',
        secretAccessKey: 'secret_test',
      ),
    );
    fakeS3.alwaysFail = Exception('network down');

    final result = await active.createNote(
      'first try',
      now: DateTime(2026, 9, 8, 12, 0, 0),
    );

    // The note is on disk immediately — the user does not retry.
    expect(result.outcome, NoteCreateOutcome.savedLocalOnly);
    expect(result.entry.id, 'ql-260908-120000.md');
    expect(
      File(p.join(tmp.path, 'ql-260908-120000.md')).readAsStringSync(),
      'first try',
    );
    expect(fakeS3.objects, isEmpty);
    // The failure still arms the degrade window for the next notes.
    expect(session.isDegraded, isTrue);

    // Second note goes local without touching S3 at all.
    final s3Calls = fakeS3.calls;
    expect(s3Calls, greaterThan(0));
    final second = await active.createNote(
      'second try',
      now: DateTime(2026, 9, 8, 12, 0, 1),
    );
    expect(second.outcome, NoteCreateOutcome.savedLocalOnly);
    expect(
      File(p.join(tmp.path, 'ql-260908-120001.md')).readAsStringSync(),
      'second try',
    );
    expect(
      fakeS3.calls,
      s3Calls,
      reason: 'degrade window must not contact S3 for the next note',
    );
  });

  test('createNote keeps one id when the S3 put lands but the '
      'response is lost', () async {
    await session.setPreferredMode(StorageMode.s3);
    await prefs.setS3Config(
      S3Config(
        endpoint: kDefaultS3Endpoint,
        region: kDefaultS3Region,
        bucket: kDefaultS3Bucket,
        accessKeyId: 'AKIA_TEST',
        secretAccessKey: 'secret_test',
      ),
    );
    fakeS3.putSucceedsButThrows = Exception('response lost');

    final result = await active.createNote(
      'maybe both',
      now: DateTime(2026, 9, 8, 15, 0, 0),
    );

    // One note, one id, in both backends: the browser renders a single
    // "both" row and the user can drop the local copy (or move it back).
    expect(result.outcome, NoteCreateOutcome.savedLocalOnly);
    expect(result.entry.id, 'ql-260908-150000.md');
    expect(
      File(p.join(tmp.path, 'ql-260908-150000.md')).readAsStringSync(),
      'maybe both',
    );
    expect(fakeS3.objects.containsKey('ql-260908-150000.md'), isTrue);
    expect(session.isDegraded, isTrue);
  });

  test('createNote rethrows ArgumentError without a local copy',
      () async {
    await session.setPreferredMode(StorageMode.s3);
    await prefs.setS3Config(
      S3Config(
        endpoint: kDefaultS3Endpoint,
        region: kDefaultS3Region,
        bucket: kDefaultS3Bucket,
        accessKeyId: 'AKIA_TEST',
        secretAccessKey: 'secret_test',
      ),
    );
    fakeS3.alwaysFail = ArgumentError('bad key');

    await expectLater(
      active.createNote('nope', now: DateTime(2026, 9, 8, 16, 0, 0)),
      throwsA(isA<ArgumentError>()),
    );
    // Bad input must not leave a local copy and must not arm the window.
    expect(Directory(tmp.path).listSync(), isEmpty);
    expect(session.isDegraded, isFalse);
  });

  test('createNote rethrows when the local fallback write fails',
      () async {
    // Put the log directory under a regular file so it cannot be created.
    await File(p.join(tmp.path, 'blocked')).writeAsString('not a directory');
    SharedPreferences.setMockInitialValues(<String, Object>{
      'flutter.Directory': p.join(tmp.path, 'blocked', 'sub'),
      'flutter.StorageMode': 's3',
      'flutter.S3AccessKeyId': 'AKIA_TEST',
      'flutter.S3SecretAccessKey': 'secret_test',
    });
    final prefs2 = PreferencesService();
    final session2 = S3SessionController(preferences: prefs2);
    await session2.load();
    await session2.setPreferredMode(StorageMode.s3);
    addTearDown(session2.dispose);
    final active2 = ActiveNoteStore(
      preferences: prefs2,
      session: session2,
      s3ClientFactory: (_) => fakeS3,
    );
    fakeS3.alwaysFail = Exception('network down');

    await expectLater(
      active2.createNote('lost', now: DateTime(2026, 9, 8, 17, 0, 0)),
      throwsA(isA<FileSystemException>()),
    );
    expect(
      Directory(tmp.path)
          .listSync()
          .where((e) => p.basename(e.path).endsWith('.md')),
      isEmpty,
    );
  });

  test('createNote with local preferred is not a fallback', () async {
    final result = await active.createNote(
      'local preferred',
      now: DateTime(2026, 9, 8, 13, 0, 0),
    );

    expect(result.outcome, NoteCreateOutcome.saved);
    expect(
      File(p.join(tmp.path, 'ql-260908-130000.md')).readAsStringSync(),
      'local preferred',
    );
    expect(fakeS3.objects, isEmpty);
  });

  test('createNote with S3 preferred but no credentials saves local',
      () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'flutter.Directory': tmp.path,
      // No access/secret keys.
    });
    final prefs2 = PreferencesService();
    final session2 = S3SessionController(preferences: prefs2);
    await session2.load();
    await session2.setPreferredMode(StorageMode.s3);
    addTearDown(session2.dispose);
    final active2 = ActiveNoteStore(
      preferences: prefs2,
      session: session2,
      s3ClientFactory: (_) => fakeS3,
    );

    final result = await active2.createNote(
      'no creds',
      now: DateTime(2026, 9, 8, 14, 0, 0),
    );

    expect(result.outcome, NoteCreateOutcome.savedLocalOnly);
    expect(result.entry.id, 'ql-260908-140000.md');
    expect(
      File(p.join(tmp.path, 'ql-260908-140000.md')).readAsStringSync(),
      'no creds',
    );
    expect(fakeS3.objects, isEmpty);
    expect(session2.isDegraded, isTrue);
  });

  test('createNote dual write saves to local and S3 when S3 is up', () async {
    await session.setPreferredMode(StorageMode.both);
    await prefs.setS3Config(
      S3Config(
        endpoint: kDefaultS3Endpoint,
        region: kDefaultS3Region,
        bucket: kDefaultS3Bucket,
        accessKeyId: 'AKIA_TEST',
        secretAccessKey: 'secret_test',
      ),
    );

    final result = await active.createNote(
      'in both',
      now: DateTime(2026, 9, 8, 15, 0, 0),
    );

    expect(result.outcome, NoteCreateOutcome.saved);
    expect(result.entry.id, 'ql-260908-150000.md');
    expect(
      File(p.join(tmp.path, 'ql-260908-150000.md')).readAsStringSync(),
      'in both',
    );
    expect(fakeS3.objects.containsKey('ql-260908-150000.md'), isTrue);
    expect(session.isDegraded, isFalse);
  });

  test('createNote dual write keeps the note local when S3 fails', () async {
    await session.setPreferredMode(StorageMode.both);
    await prefs.setS3Config(
      S3Config(
        endpoint: kDefaultS3Endpoint,
        region: kDefaultS3Region,
        bucket: kDefaultS3Bucket,
        accessKeyId: 'AKIA_TEST',
        secretAccessKey: 'secret_test',
      ),
    );
    fakeS3.alwaysFail = Exception('network down');

    final result = await active.createNote(
      'local during outage',
      now: DateTime(2026, 9, 8, 15, 1, 0),
    );

    expect(result.outcome, NoteCreateOutcome.savedLocalOnly);
    expect(result.entry.id, 'ql-260908-150100.md');
    expect(
      File(p.join(tmp.path, 'ql-260908-150100.md')).readAsStringSync(),
      'local during outage',
    );
    expect(fakeS3.objects, isEmpty);
    expect(session.isDegraded, isTrue);

    // Next note: local only, without contacting S3 again.
    final s3Calls = fakeS3.calls;
    expect(s3Calls, greaterThan(0));
    final second = await active.createNote(
      'still local',
      now: DateTime(2026, 9, 8, 15, 1, 1),
    );
    expect(second.outcome, NoteCreateOutcome.savedLocalOnly);
    expect(
      File(p.join(tmp.path, 'ql-260908-150101.md')).readAsStringSync(),
      'still local',
    );
    expect(fakeS3.calls, s3Calls, reason: 'degrade window skips S3');
  });

  test('createNote dual write keeps the note in S3 when local fails',
      () async {
    // Put the log directory under a regular file so it cannot be created.
    await File(p.join(tmp.path, 'blocked')).writeAsString('not a directory');
    SharedPreferences.setMockInitialValues(<String, Object>{
      'flutter.Directory': p.join(tmp.path, 'blocked', 'sub'),
      'flutter.StorageMode': 'both',
      'flutter.S3AccessKeyId': 'AKIA_TEST',
      'flutter.S3SecretAccessKey': 'secret_test',
    });
    final prefs2 = PreferencesService();
    final session2 = S3SessionController(preferences: prefs2);
    await session2.load();
    addTearDown(session2.dispose);
    final active2 = ActiveNoteStore(
      preferences: prefs2,
      session: session2,
      s3ClientFactory: (_) => fakeS3,
    );

    final result = await active2.createNote(
      'bucket only',
      now: DateTime(2026, 9, 8, 15, 2, 0),
    );

    // The note is safe in the bucket; the outcome reports the missing local
    // copy instead of a hard error (a retry would duplicate it in S3).
    expect(result.outcome, NoteCreateOutcome.savedS3Only);
    expect(result.entry.id, 'ql-260908-150200.md');
    expect(fakeS3.objects.containsKey('ql-260908-150200.md'), isTrue);
    expect(session2.isDegraded, isFalse);
  });

  test('createNote dual write reports the local copy when S3 throws '
      'ArgumentError', () async {
    await session.setPreferredMode(StorageMode.both);
    await prefs.setS3Config(
      S3Config(
        endpoint: kDefaultS3Endpoint,
        region: kDefaultS3Region,
        bucket: kDefaultS3Bucket,
        accessKeyId: 'AKIA_TEST',
        secretAccessKey: 'secret_test',
      ),
    );
    fakeS3.alwaysFail = ArgumentError('bad key');

    final result = await active.createNote(
      'orphan check',
      now: DateTime(2026, 9, 8, 15, 4, 0),
    );

    // The local file already landed; report it instead of erroring and
    // leaving it unreported (a re-log would duplicate it).
    expect(result.outcome, NoteCreateOutcome.savedLocalOnly);
    expect(result.entry.id, 'ql-260908-150400.md');
    expect(
      File(p.join(tmp.path, 'ql-260908-150400.md')).readAsStringSync(),
      'orphan check',
    );
    expect(fakeS3.objects, isEmpty);
  });

  test('resolve() in dual mode returns the local store', () async {
    await session.setPreferredMode(StorageMode.both);
    await prefs.setS3Config(
      S3Config(
        endpoint: kDefaultS3Endpoint,
        region: kDefaultS3Region,
        bucket: kDefaultS3Bucket,
        accessKeyId: 'AKIA_TEST',
        secretAccessKey: 'secret_test',
      ),
    );

    final store = await active.resolve();
    expect(store, isA<LocalNoteStore>());
  });

  test('createNote dual write throws when both backends fail', () async {
    await File(p.join(tmp.path, 'blocked')).writeAsString('not a directory');
    SharedPreferences.setMockInitialValues(<String, Object>{
      'flutter.Directory': p.join(tmp.path, 'blocked', 'sub'),
      'flutter.StorageMode': 'both',
      'flutter.S3AccessKeyId': 'AKIA_TEST',
      'flutter.S3SecretAccessKey': 'secret_test',
    });
    final prefs2 = PreferencesService();
    final session2 = S3SessionController(preferences: prefs2);
    await session2.load();
    addTearDown(session2.dispose);
    final active2 = ActiveNoteStore(
      preferences: prefs2,
      session: session2,
      s3ClientFactory: (_) => fakeS3,
    );
    fakeS3.alwaysFail = Exception('network down');

    await expectLater(
      active2.createNote('lost', now: DateTime(2026, 9, 8, 15, 3, 0)),
      throwsA(isA<FileSystemException>()),
    );
    expect(fakeS3.objects, isEmpty);
  });

  test('preferred S3 with empty credentials falls back to local + degrades',
      () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'flutter.Directory': tmp.path,
      // No access/secret keys.
    });
    prefs = PreferencesService();
    session.dispose();
    session = S3SessionController(preferences: prefs);
    await session.load();
    await session.setPreferredMode(StorageMode.s3);
    active = ActiveNoteStore(
      preferences: prefs,
      session: session,
      s3ClientFactory: (_) => fakeS3,
    );

    final resolved = await active.resolve();
    expect(session.isDegraded, isTrue);
    expect(session.usesLocalFallback, isTrue);

    final entry = await resolved.create(
      'no creds local',
      now: DateTime(2026, 9, 8, 7, 0, 0),
    );
    expect(File(p.join(tmp.path, entry.id)).existsSync(), isTrue);
    expect(fakeS3.objects, isEmpty);
  });

  testWidgets('browser re-resolves to local after session degrades',
      (tester) async {
    await session.setPreferredMode(StorageMode.s3);
    await prefs.setS3Config(
      S3Config(
        endpoint: kDefaultS3Endpoint,
        region: kDefaultS3Region,
        bucket: kDefaultS3Bucket,
        accessKeyId: 'AKIA_TEST',
        secretAccessKey: 'secret_test',
      ),
    );
    final s3Store = await active.resolve();
    await s3Store.create(
      'on s3 only',
      now: DateTime(2026, 9, 8, 9, 30, 0),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: EntryBrowserScreen(session: session, activeStore: active),
      ),
    );
    await pumpWithIo(tester);
    expect(find.textContaining('on s3 only'), findsWidgets);

    // Local-only note written while S3 is still preferred; after degrade the
    // browser still merges both backends when S3 is preferred.
    await tester.runAsync(() async {
      await File(p.join(tmp.path, 'ql-260908-093100.md'))
          .writeAsString('local after degrade');
    });

    await tester.runAsync(() => session.markS3Failed());
    await pumpWithIo(tester);

    expect(find.textContaining('local after degrade'), findsWidgets);
    expect(find.textContaining('on s3 only'), findsWidgets);
    expect(
      find.text('Using local (S3 unavailable). Retry or wait until the '
          'degrade window ends.'),
      findsOneWidget,
    );
  });

  testWidgets('when S3 preferred, browser lists local and S3 with badges '
      'and can move local-only notes', (tester) async {
    await session.setPreferredMode(StorageMode.s3);
    await prefs.setS3Config(
      S3Config(
        endpoint: kDefaultS3Endpoint,
        region: kDefaultS3Region,
        bucket: kDefaultS3Bucket,
        accessKeyId: 'AKIA_TEST',
        secretAccessKey: 'secret_test',
      ),
    );
    final s3Store = await active.resolve();
    await s3Store.create(
      'remote note',
      now: DateTime(2026, 9, 8, 10, 0, 0),
    );
    await tester.runAsync(() async {
      await File(p.join(tmp.path, 'ql-260908-090000.md'))
          .writeAsString('local leftover');
    });

    await tester.pumpWidget(
      MaterialApp(
        home: EntryBrowserScreen(session: session, activeStore: active),
      ),
    );
    await pumpWithIo(tester);

    expect(find.textContaining('remote note'), findsWidgets);
    expect(find.textContaining('local leftover'), findsWidgets);
    expect(find.byIcon(Icons.cloud_outlined), findsOneWidget);
    expect(find.byIcon(Icons.folder_outlined), findsOneWidget);
    expect(find.byTooltip('Move to S3'), findsOneWidget);

    await tester.tap(find.byTooltip('Move to S3'));
    await pumpWithIo(tester);

    expect(find.textContaining('Moved ql-260908-090000.md to S3'), findsOneWidget);
    expect(
      await tester.runAsync(
        () async => File(p.join(tmp.path, 'ql-260908-090000.md')).exists(),
      ),
      isFalse,
    );
    expect(fakeS3.objects.containsKey('ql-260908-090000.md'), isTrue);
    expect(find.byIcon(Icons.folder_outlined), findsNothing);
    expect(find.byTooltip('Move to S3'), findsNothing);
  });

  testWidgets('shows list-failure banner and still lists local notes',
      (tester) async {
    await session.setPreferredMode(StorageMode.s3);
    await prefs.setS3Config(
      S3Config(
        endpoint: kDefaultS3Endpoint,
        region: kDefaultS3Region,
        bucket: kDefaultS3Bucket,
        accessKeyId: 'AKIA_TEST',
        secretAccessKey: 'secret_test',
      ),
    );
    await tester.runAsync(() async {
      await File(p.join(tmp.path, 'ql-260908-070000.md'))
          .writeAsString('local while s3 down');
    });
    fakeS3.alwaysFail = Exception('list failed');

    await tester.pumpWidget(
      MaterialApp(
        home: EntryBrowserScreen(session: session, activeStore: active),
      ),
    );
    await pumpWithIo(tester);

    expect(
      find.textContaining('Could not list S3 notes'),
      findsOneWidget,
    );
    expect(find.textContaining('local while s3 down'), findsWidgets);
    expect(find.byTooltip('Move to S3'), findsNothing);
    expect(session.isDegraded, isFalse);
  });

  testWidgets('both-location row can remove the local copy', (tester) async {
    await session.setPreferredMode(StorageMode.s3);
    await prefs.setS3Config(
      S3Config(
        endpoint: kDefaultS3Endpoint,
        region: kDefaultS3Region,
        bucket: kDefaultS3Bucket,
        accessKeyId: 'AKIA_TEST',
        secretAccessKey: 'secret_test',
      ),
    );
    const id = 'ql-260908-060000.md';
    await tester.runAsync(() async {
      await File(p.join(tmp.path, id)).writeAsString('dup local');
      await fakeS3.putText(id, 'dup s3');
    });

    await tester.pumpWidget(
      MaterialApp(
        home: EntryBrowserScreen(session: session, activeStore: active),
      ),
    );
    await pumpWithIo(tester);

    expect(find.byIcon(Icons.cloud_sync_outlined), findsOneWidget);
    expect(find.byTooltip('Remove local copy'), findsOneWidget);

    await tester.tap(find.byTooltip('Remove local copy'));
    await pumpWithIo(tester);

    expect(find.textContaining('Removed local copy of $id'), findsOneWidget);
    expect(
      await tester.runAsync(() async => File(p.join(tmp.path, id)).exists()),
      isFalse,
    );
    expect(fakeS3.objects.containsKey(id), isTrue);
    expect(find.byIcon(Icons.cloud_outlined), findsOneWidget);
  });

  testWidgets('Move all local aborts when a fresh S3 list fails',
      (tester) async {
    await session.setPreferredMode(StorageMode.s3);
    await prefs.setS3Config(
      S3Config(
        endpoint: kDefaultS3Endpoint,
        region: kDefaultS3Region,
        bucket: kDefaultS3Bucket,
        accessKeyId: 'AKIA_TEST',
        secretAccessKey: 'secret_test',
      ),
    );
    const id = 'ql-260908-050000.md';
    await tester.runAsync(() async {
      await File(p.join(tmp.path, id)).writeAsString('do not move');
      await fakeS3.putText(id, 'already remote');
    });

    await tester.pumpWidget(
      MaterialApp(
        home: EntryBrowserScreen(session: session, activeStore: active),
      ),
    );
    await pumpWithIo(tester);
    expect(find.byTooltip('Move all local to S3'), findsOneWidget);

    fakeS3.alwaysFail = Exception('list failed mid move-all');
    await tester.tap(find.byTooltip('Move all local to S3'));
    await pumpWithIo(tester);

    expect(find.textContaining('move cancelled'), findsOneWidget);
    expect(
      await tester.runAsync(() async => File(p.join(tmp.path, id)).exists()),
      isTrue,
    );
  });

  test('listForBrowser merges when S3 preferred and stays local-only otherwise',
      () async {
    await File(p.join(tmp.path, 'ql-260908-080000.md'))
        .writeAsString('only local mode');
    var listed = await active.listForBrowser();
    expect(listed, hasLength(1));
    expect(listed.single.location, NoteStorageLocation.local);

    await session.setPreferredMode(StorageMode.s3);
    await prefs.setS3Config(
      S3Config(
        endpoint: kDefaultS3Endpoint,
        region: kDefaultS3Region,
        bucket: kDefaultS3Bucket,
        accessKeyId: 'AKIA_TEST',
        secretAccessKey: 'secret_test',
      ),
    );
    await fakeS3.putText('ql-260908-081000.md', 'from bucket');
    listed = await active.listForBrowser();
    expect(listed, hasLength(2));
    expect(
      listed.map((e) => e.location).toSet(),
      {NoteStorageLocation.local, NoteStorageLocation.s3},
    );

    // Dual mode keeps merging; a note in both places becomes one 'both' row.
    await session.setPreferredMode(StorageMode.both);
    await File(p.join(tmp.path, 'ql-260908-081000.md')).writeAsString('mirror');
    listed = await active.listForBrowser();
    expect(listed, hasLength(2));
    expect(
      listed.map((e) => e.location).toSet(),
      {NoteStorageLocation.local, NoteStorageLocation.both},
    );
  });

  testWidgets('Test connection probes without persisting secrets',
      (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'flutter.Directory': tmp.path,
    });
    prefs = PreferencesService();
    session.dispose();
    session = S3SessionController(preferences: prefs);
    await session.load();
    final probeClient = MemoryS3ObjectClient();
    active = ActiveNoteStore(
      preferences: prefs,
      session: session,
      s3ClientFactory: (_) => probeClient,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: PreferencesScreen(
          session: session,
          activeStore: active,
          s3ClientFactory: (_) => probeClient,
        ),
      ),
    );
    await pumpWithIo(tester);

    await tester.tap(find.text('S3 only'));
    await tester.pump();
    await tester.drag(find.byType(ListView), const Offset(0, -600));
    await tester.pump();

    final secretField = find.byWidgetPredicate(
      (w) => w is TextField && w.obscureText,
    );
    expect(secretField, findsOneWidget);

    final fields = find.byType(TextField);
    final fieldCount = tester.widgetList(fields).length;
    // Access key is the TextField immediately before the obscure secret field.
    final accessKeyField = fields.at(fieldCount - 2);

    await tester.enterText(accessKeyField, 'TEMP_KEY_NOT_SAVED');
    await tester.enterText(secretField, 'TEMP_SECRET_NOT_SAVED');
    await tester.pump();

    await tester.ensureVisible(find.text('Test connection'));
    await tester.tap(find.text('Test connection'));
    await pumpWithIo(tester);

    expect(find.text('S3 connection OK.'), findsOneWidget);

    final saved = await prefs.s3Config();
    expect(saved.accessKeyId, isEmpty);
    expect(saved.secretAccessKey, isEmpty);
  });
}
