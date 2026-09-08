import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:quicklog/screens/entry_browser_screen.dart';
import 'package:quicklog/screens/preferences_screen.dart';
import 'package:quicklog/services/active_note_store.dart';
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
}
