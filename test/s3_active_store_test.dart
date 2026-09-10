import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:quicklog/screens/entry_browser_screen.dart';
import 'package:quicklog/screens/preferences_screen.dart';
import 'package:quicklog/services/active_note_store.dart';
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
