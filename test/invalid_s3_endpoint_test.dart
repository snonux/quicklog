import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:quicklog/screens/entry_browser_screen.dart';
import 'package:quicklog/screens/home_screen.dart';
import 'package:quicklog/screens/preferences_screen.dart';
import 'package:quicklog/services/active_note_store.dart';
import 'package:quicklog/services/merged_note_listing.dart';
import 'package:quicklog/services/preferences.dart';
import 'package:quicklog/services/s3_config.dart';
import 'package:quicklog/services/s3_object_client.dart';
import 'package:quicklog/services/s3_session_controller.dart';
import 'package:quicklog/services/settings_backup.dart';
import 'package:quicklog/services/settings_file_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../bin/quicklog_drain.dart' as drain;
import 'io_pump.dart';
import 'support/memory_s3_object_client.dart';

/// Saved S3 settings that no client can be built from (e.g. an invalid
/// endpoint) must not blank the entry browser or lose a note, and every path
/// that stores settings (Save, Export, Import) refuses them while S3 is used.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const localId = 'ql-260908-070000.md';
  const localText = 'local note survives';
  // One endpoint per failure path: S3Config.host (no host) and Minio's own
  // domain validation (leading underscore).
  const invalidEndpoints = ['http://', 'https://_bad.example'];

  late Directory tmp;
  late PreferencesService prefs;
  late S3SessionController session;
  // Pure configError tests never load a session, so nothing to dispose.
  var sessionLoaded = false;

  /// Seeds prefs with S3 credentials, [mode] and [endpoint], then loads the
  /// session from them.
  Future<void> setUpPrefs({
    required StorageMode mode,
    String? endpoint,
    String? bucket,
  }) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'flutter.Directory': tmp.path,
      'flutter.StorageMode': mode.name,
      'flutter.S3AccessKeyId': 'AKIA_TEST',
      'flutter.S3SecretAccessKey': 'secret_test',
      'flutter.S3Endpoint': ?endpoint,
      'flutter.S3Bucket': ?bucket,
    });
    prefs = PreferencesService();
    session = S3SessionController(preferences: prefs);
    await session.load();
    sessionLoaded = true;
  }

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('ql-bad-endpoint-');
    await File(p.join(tmp.path, localId)).writeAsString(localText);
    sessionLoaded = false;
  });

  tearDown(() async {
    if (sessionLoaded) session.dispose();
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  group('MinioS3ObjectClient.configError', () {
    test('accepts the default and a host:port endpoint', () {
      for (final endpoint in [
        kDefaultS3Endpoint,
        'http://localhost:3900',
        'garage.example.org',
      ]) {
        expect(
          MinioS3ObjectClient.configError(_config(endpoint)),
          isNull,
          reason: endpoint,
        );
      }
    });

    test('explains invalid endpoints without the exception type', () {
      expect(
        MinioS3ObjectClient.configError(_config('http://')),
        'S3 endpoint has no host: http://',
      );
      final minio = MinioS3ObjectClient.configError(
        _config('https://_bad.example'),
      );
      expect(minio, contains('_bad.example'));
      expect(minio, isNot(startsWith('MinioError')));
    });

    test('rejects an invalid bucket name; bucket names in use still pass', () {
      expect(
        MinioS3ObjectClient.configError(_config(kDefaultS3Endpoint, 'Bad_B')),
        'Invalid bucket name: Bad_B',
      );
      for (final bucket in [
        kDefaultS3Bucket,
        'my-notes',
        'other-bucket',
        'ql-backup-test',
      ]) {
        expect(
          MinioS3ObjectClient.configError(_config(kDefaultS3Endpoint, bucket)),
          isNull,
          reason: bucket,
        );
      }
    });

    test('the constructor throws S3ConfigException for the same cases', () {
      expect(
        () => MinioS3ObjectClient(_config('http://')),
        throwsA(isA<S3ConfigException>()),
      );
      expect(
        () => MinioS3ObjectClient(_config(kDefaultS3Endpoint, 'Bad_B')),
        throwsA(isA<S3ConfigException>()),
      );
    });
  });

  group('resolveBrowserSources', () {
    for (final mode in [StorageMode.s3, StorageMode.both]) {
      for (final endpoint in invalidEndpoints) {
        test('${mode.name} mode, endpoint "$endpoint": lists local notes '
            'and reports the setup error', () async {
          await setUpPrefs(mode: mode, endpoint: endpoint);
          // Real Minio factory: building the client is where it throws.
          final active = ActiveNoteStore(preferences: prefs, session: session);

          final sources = await active.resolveBrowserSources();
          final listed = await sources.list();

          expect(sources.s3, isNull);
          expect(sources.mergeWhenS3Preferred, isTrue);
          expect(sources.s3SetupError, isNotNull);
          expect(sources.s3ListFailed, isTrue);
          expect(listed.single.id, localId);
          expect(listed.single.location, NoteStorageLocation.local);
          // A config problem is not an outage: no degrade window.
          expect(session.isDegraded, isFalse);
        });
      }
    }

    test('invalid bucket name: lists local notes and reports it', () async {
      await setUpPrefs(mode: StorageMode.both, bucket: 'Bad_B');
      final active = ActiveNoteStore(preferences: prefs, session: session);

      final sources = await active.resolveBrowserSources();
      final listed = await sources.list();

      expect(sources.s3, isNull);
      expect(sources.s3SetupError, 'Invalid bucket name: Bad_B');
      expect(sources.s3ListFailed, isTrue);
      expect(listed.single.id, localId);
    });

    test('errors that are not about the settings still propagate', () async {
      await setUpPrefs(mode: StorageMode.s3);
      final active = ActiveNoteStore(
        preferences: prefs,
        session: session,
        s3ClientFactory: (_) => throw StateError('secure storage broke'),
      );

      await expectLater(
        active.resolveBrowserSources(),
        throwsA(isA<StateError>()),
      );
    });

    test('valid endpoint builds S3 as before', () async {
      await setUpPrefs(mode: StorageMode.s3);
      final fake = MemoryS3ObjectClient();
      await fake.putText('ql-260908-081000.md', 'from bucket');
      final active = ActiveNoteStore(
        preferences: prefs,
        session: session,
        s3ClientFactory: (_) => fake,
      );

      final sources = await active.resolveBrowserSources();
      final listed = await sources.list();

      expect(sources.s3, isNotNull);
      expect(sources.s3SetupError, isNull);
      expect(sources.s3ListFailed, isFalse);
      expect(listed.map((e) => e.location).toSet(), {
        NoteStorageLocation.local,
        NoteStorageLocation.s3,
      });
    });

    test(
      'local mode never builds a client, even with a bad endpoint',
      () async {
        await setUpPrefs(mode: StorageMode.local, endpoint: 'http://');
        final active = ActiveNoteStore(
          preferences: prefs,
          session: session,
          s3ClientFactory: (_) => fail('no S3 client in local mode'),
        );

        final sources = await active.resolveBrowserSources();
        final listed = await sources.list();

        expect(sources.s3, isNull);
        expect(sources.mergeWhenS3Preferred, isFalse);
        expect(sources.s3SetupError, isNull);
        expect(sources.s3ListFailed, isFalse);
        expect(listed.single.id, localId);
      },
    );
  });

  group('createNote', () {
    const stamp = '260927-101500';
    final now = DateTime(2026, 9, 27, 10, 15);

    for (final mode in [StorageMode.s3, StorageMode.both]) {
      test('${mode.name} mode, invalid endpoint: saves locally and reports '
          'the settings, not an outage', () async {
        await setUpPrefs(mode: mode, endpoint: 'http://');
        final active = ActiveNoteStore(preferences: prefs, session: session);

        final result = await active.createNote('kept locally', now: now);

        expect(result.outcome, NoteCreateOutcome.savedLocalS3SettingsInvalid);
        expect(result.entry.id, 'ql-$stamp.md');
        expect(
          await File(p.join(tmp.path, 'ql-$stamp.md')).readAsString(),
          'kept locally',
        );
        expect(session.isDegraded, isFalse);
      });
    }

    test('valid settings save to S3 as before', () async {
      await setUpPrefs(mode: StorageMode.s3);
      final fake = MemoryS3ObjectClient();
      final active = ActiveNoteStore(
        preferences: prefs,
        session: session,
        s3ClientFactory: (_) => fake,
      );

      final result = await active.createNote('to bucket', now: now);

      expect(result.outcome, NoteCreateOutcome.saved);
      expect(fake.objects.keys, ['ql-$stamp.md']);
    });

    testWidgets('home screen says to check Preferences', (tester) async {
      await setUpPrefs(mode: StorageMode.both, endpoint: 'http://');
      await tester.pumpWidget(
        MaterialApp(
          home: HomeScreen(
            session: session,
            activeStore: ActiveNoteStore(preferences: prefs, session: session),
          ),
        ),
      );
      await pumpWithIo(tester);

      await tester.enterText(find.byType(TextField), 'typed note');
      await tester.tap(find.widgetWithText(FilledButton, 'Log text'));
      await pumpWithIo(tester);

      expect(
        find.text(
          'S3 settings invalid — the note was saved on this device. '
          'Check Preferences.',
        ),
        findsOneWidget,
      );
      expect(find.textContaining('S3 unavailable'), findsNothing);
      // Let the snackbar's display timer run out on the fake clock.
      await tester.pump(const Duration(seconds: 5));
    });
  });

  group('settings import', () {
    SettingsBackupService service() =>
        SettingsBackupService(preferences: prefs, session: session);

    test(
      'refuses an invalid endpoint for an S3 mode and writes nothing',
      () async {
        await setUpPrefs(mode: StorageMode.local);
        const incoming = QuicklogSettings(
          directory: '/elsewhere',
          storageMode: StorageMode.both,
          s3Endpoint: 'http://',
        );

        await expectLater(
          service().apply(incoming),
          throwsA(
            isA<SettingsImportException>().having(
              (e) => e.message,
              'message',
              'Invalid S3 settings: S3 endpoint has no host: http://',
            ),
          ),
        );
        expect(await prefs.directory(), tmp.path);
        expect(await prefs.storageMode(), StorageMode.local);
        expect(session.preferredMode, StorageMode.local);
        expect((await prefs.s3Config()).endpoint, kDefaultS3Endpoint);
      },
    );

    test('checks against the current mode when the file has none', () async {
      await setUpPrefs(mode: StorageMode.s3);
      await expectLater(
        service().apply(const QuicklogSettings(s3Bucket: 'Bad_B')),
        throwsA(isA<SettingsImportException>()),
      );
      expect((await prefs.s3Config()).bucket, kDefaultS3Bucket);
    });

    // Checked as stored settings read back: trimmed, empty -> default.
    for (final bucket in ['', ' quicklog ']) {
      test(
        'S3 mode imports bucket "$bucket" as it will be read back',
        () async {
          await setUpPrefs(mode: StorageMode.local);
          await service().apply(
            QuicklogSettings(storageMode: StorageMode.s3, s3Bucket: bucket),
          );
          expect(session.preferredMode, StorageMode.s3);
          expect((await prefs.s3Config()).bucket, kDefaultS3Bucket);
        },
      );
    }

    test('local mode imports an unused invalid endpoint', () async {
      await setUpPrefs(mode: StorageMode.s3);
      await service().apply(
        const QuicklogSettings(
          storageMode: StorageMode.local,
          s3Endpoint: 'http://',
        ),
      );
      expect(session.preferredMode, StorageMode.local);
      expect((await prefs.s3Config()).endpoint, 'http://');
    });
  });

  group('quicklog_drain', () {
    const creds = {
      'GARAGE_ACCESS_KEY_ID': 'AKIA_TEST',
      'GARAGE_SECRET_ACCESS_KEY': 'secret_test',
    };

    test('reports an invalid endpoint instead of throwing', () {
      expect(
        drain.configProblem(
          drain.configFromEnv({...creds, 'GARAGE_ENDPOINT': 'http://'}),
        ),
        'invalid S3 settings: S3 endpoint has no host: http://',
      );
    });

    test('still reports missing credentials first', () {
      expect(
        drain.configProblem(drain.configFromEnv({'GARAGE_ENDPOINT': 'x://'})),
        startsWith('missing GARAGE_ACCESS_KEY_ID'),
      );
    });

    test('accepts valid settings', () {
      expect(drain.configProblem(drain.configFromEnv(creds)), isNull);
    });
  });

  group('entry browser', () {
    Future<void> pumpBrowser(
      WidgetTester tester,
      ActiveNoteStore active,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: EntryBrowserScreen(session: session, activeStore: active),
        ),
      );
      await pumpWithIo(tester);
    }

    testWidgets('invalid endpoint still lists local notes and shows why', (
      tester,
    ) async {
      await setUpPrefs(mode: StorageMode.both, endpoint: 'http://');
      await pumpBrowser(
        tester,
        ActiveNoteStore(preferences: prefs, session: session),
      );

      expect(find.textContaining(localText), findsWidgets);
      expect(find.textContaining('Error:'), findsNothing);
      expect(find.textContaining('Could not list S3 notes'), findsOneWidget);
      expect(
        find.text(
          'Check the S3 settings in Preferences: '
          'S3 endpoint has no host: http://',
        ),
        findsOneWidget,
      );
      expect(find.byTooltip('Move to S3'), findsNothing);
      expect(find.byTooltip('Move all local to S3'), findsNothing);
    });

    testWidgets('valid endpoint shows no banner and keeps Move to S3', (
      tester,
    ) async {
      await setUpPrefs(mode: StorageMode.s3);
      await pumpBrowser(
        tester,
        ActiveNoteStore(
          preferences: prefs,
          session: session,
          s3ClientFactory: (_) => MemoryS3ObjectClient(),
        ),
      );

      expect(find.textContaining(localText), findsWidgets);
      expect(find.textContaining('Could not list S3 notes'), findsNothing);
      expect(find.textContaining('Check the S3 settings'), findsNothing);
      expect(find.byTooltip('Move to S3'), findsOneWidget);
    });

    testWidgets('no S3 configured shows local notes without a banner', (
      tester,
    ) async {
      await setUpPrefs(mode: StorageMode.local);
      await pumpBrowser(
        tester,
        ActiveNoteStore(preferences: prefs, session: session),
      );

      expect(find.textContaining(localText), findsWidgets);
      expect(find.textContaining('Could not list S3 notes'), findsNothing);
      expect(find.byTooltip('Move to S3'), findsNothing);
    });
  });

  group('Preferences', () {
    late _FakeSettingsFiles files;

    /// Opens Preferences on top of a host page so a successful Save (which
    /// pops) is observable.
    Future<void> openPreferences(WidgetTester tester) async {
      files = _FakeSettingsFiles();
      final active = ActiveNoteStore(preferences: prefs, session: session);
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (ctx) => TextButton(
              onPressed: () => Navigator.of(ctx).push(
                MaterialPageRoute<void>(
                  builder: (_) => PreferencesScreen(
                    session: session,
                    activeStore: active,
                    settingsFiles: files,
                  ),
                ),
              ),
              child: const Text('host'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('host'));
      await pumpWithIo(tester);
    }

    Future<String?> savedEndpoint(WidgetTester tester) async =>
        tester.runAsync(() async => (await prefs.s3Config()).endpoint);

    Future<StorageMode?> savedMode(WidgetTester tester) async =>
        tester.runAsync(() => prefs.storageMode());

    /// Scrolls the lazily built Preferences list to [finder] and taps it.
    Future<void> tapScrolled(WidgetTester tester, Finder finder) async {
      await tester.scrollUntilVisible(
        finder,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(finder);
      await pumpWithIo(tester);
    }

    const rejected = 'Invalid S3 settings: S3 endpoint has no host: http://';

    testWidgets('rejects an invalid endpoint while S3 is in use', (
      tester,
    ) async {
      await setUpPrefs(mode: StorageMode.s3, endpoint: kDefaultS3Endpoint);
      await openPreferences(tester);

      await tester.enterText(
        find.byKey(const ValueKey('prefs.s3Endpoint')),
        'http://',
      );
      await tester.tap(find.byTooltip('Save'));
      await pumpWithIo(tester);

      expect(find.text(rejected), findsOneWidget);
      expect(find.byType(PreferencesScreen), findsOneWidget);
      expect(await savedEndpoint(tester), kDefaultS3Endpoint);
      expect(await savedMode(tester), StorageMode.s3);
    });

    testWidgets('switching local to S3 checks an already-saved bad endpoint', (
      tester,
    ) async {
      await setUpPrefs(mode: StorageMode.local, endpoint: 'http://');
      await openPreferences(tester);

      await tester.tap(find.text('Local + S3'));
      await tester.pump();
      await tester.tap(find.byTooltip('Save'));
      await pumpWithIo(tester);

      expect(find.text(rejected), findsOneWidget);
      expect(find.byType(PreferencesScreen), findsOneWidget);
      expect(await savedMode(tester), StorageMode.local);
      expect(session.preferredMode, StorageMode.local);
    });

    testWidgets('Export refuses an invalid endpoint before saving anything', (
      tester,
    ) async {
      await setUpPrefs(mode: StorageMode.s3, endpoint: kDefaultS3Endpoint);
      await openPreferences(tester);

      await tester.enterText(
        find.byKey(const ValueKey('prefs.s3Endpoint')),
        'http://',
      );
      await tapScrolled(tester, find.text('Export settings'));

      expect(find.text(rejected), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Export'), findsNothing);
      expect(files.saved, isEmpty);
      expect(await savedEndpoint(tester), kDefaultS3Endpoint);
    });

    testWidgets('Import refuses an invalid endpoint and changes nothing', (
      tester,
    ) async {
      await setUpPrefs(mode: StorageMode.local);
      await openPreferences(tester);
      files.toOpen = encodeSettingsBackup(
        const QuicklogSettings(
          storageMode: StorageMode.s3,
          s3Endpoint: 'http://',
        ),
        exportedAt: DateTime.utc(2026, 9, 27),
      );

      await tapScrolled(tester, find.text('Import settings'));
      await tester.tap(find.widgetWithText(FilledButton, 'Import'));
      await pumpWithIo(tester);

      expect(find.text('Import failed'), findsOneWidget);
      expect(find.text(rejected), findsOneWidget);
      expect(await savedMode(tester), StorageMode.local);
      expect(await savedEndpoint(tester), kDefaultS3Endpoint);
    });

    testWidgets('saves a valid endpoint as before', (tester) async {
      await setUpPrefs(mode: StorageMode.s3, endpoint: kDefaultS3Endpoint);
      await openPreferences(tester);

      await tester.enterText(
        find.byKey(const ValueKey('prefs.s3Endpoint')),
        'http://localhost:3900',
      );
      await tester.tap(find.byTooltip('Save'));
      await pumpWithIo(tester);

      expect(find.byType(PreferencesScreen), findsNothing);
      expect(await savedEndpoint(tester), 'http://localhost:3900');
    });

    testWidgets('local mode saves without checking the unused endpoint', (
      tester,
    ) async {
      await setUpPrefs(mode: StorageMode.local, endpoint: 'http://');
      await openPreferences(tester);

      await tester.tap(find.byTooltip('Save'));
      await pumpWithIo(tester);

      expect(find.textContaining('Invalid S3 settings'), findsNothing);
      expect(find.byType(PreferencesScreen), findsNothing);
    });
  });
}

S3Config _config(String endpoint, [String bucket = kDefaultS3Bucket]) =>
    S3Config(
      endpoint: endpoint,
      region: kDefaultS3Region,
      bucket: bucket,
      accessKeyId: 'AKIA_TEST',
      secretAccessKey: 'secret_test',
    );

/// In-memory [SettingsFileGateway]: records saves, serves [toOpen].
class _FakeSettingsFiles implements SettingsFileGateway {
  final List<String> saved = [];
  String? toOpen;

  @override
  Future<String?> save({
    required String suggestedName,
    required String content,
  }) async {
    saved.add(content);
    return suggestedName;
  }

  @override
  Future<String?> open() async => toOpen;
}
