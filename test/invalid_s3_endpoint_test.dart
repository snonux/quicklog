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

/// A saved S3 endpoint that no client can be built from must not blank the
/// entry browser: local notes still list, and the reason is shown.
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
  Future<void> setUpPrefs({required StorageMode mode, String? endpoint}) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'flutter.Directory': tmp.path,
      'flutter.StorageMode': mode.name,
      'flutter.S3AccessKeyId': 'AKIA_TEST',
      'flutter.S3SecretAccessKey': 'secret_test',
      'flutter.S3Endpoint': ?endpoint,
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

  group('Preferences Save', () {
    /// Opens Preferences on top of a host page so a successful Save (which
    /// pops) is observable.
    Future<void> openPreferences(WidgetTester tester) async {
      final active = ActiveNoteStore(preferences: prefs, session: session);
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (ctx) => TextButton(
              onPressed: () => Navigator.of(ctx).push(
                MaterialPageRoute<void>(
                  builder: (_) =>
                      PreferencesScreen(session: session, activeStore: active),
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

      expect(
        find.text('Invalid S3 settings: S3 endpoint has no host: http://'),
        findsOneWidget,
      );
      expect(find.byType(PreferencesScreen), findsOneWidget);
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

S3Config _config(String endpoint) => S3Config(
  endpoint: endpoint,
  region: kDefaultS3Region,
  bucket: kDefaultS3Bucket,
  accessKeyId: 'AKIA_TEST',
  secretAccessKey: 'secret_test',
);
