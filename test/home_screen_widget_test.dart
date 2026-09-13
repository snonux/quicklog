import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:quicklog/screens/home_screen.dart';
import 'package:quicklog/services/active_note_store.dart';
import 'package:quicklog/services/preferences.dart';
import 'package:quicklog/services/s3_object_client.dart';
import 'package:quicklog/services/s3_session_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'io_pump.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late S3SessionController session;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    session = S3SessionController();
    await session.load();
  });

  tearDown(() {
    session.dispose();
  });

  testWidgets('character counter updates as user types', (tester) async {
    await tester.pumpWidget(MaterialApp(home: HomeScreen(session: session)));
    await tester.pumpAndSettle();

    expect(find.text('0 chars'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'hello');
    await tester.pump();
    expect(find.text('5 chars'), findsOneWidget);
  });

  testWidgets('Clear button empties the input', (tester) async {
    await tester.pumpWidget(MaterialApp(home: HomeScreen(session: session)));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'something');
    await tester.pump();
    expect(find.text('9 chars'), findsOneWidget);

    await tester.tap(find.text('Clear'));
    await tester.pump();
    expect(find.text('0 chars'), findsOneWidget);
  });

  testWidgets('Log text button is rendered and enabled', (tester) async {
    await tester.pumpWidget(MaterialApp(home: HomeScreen(session: session)));
    await tester.pumpAndSettle();

    final btn = find.widgetWithText(FilledButton, 'Log text');
    expect(btn, findsOneWidget);
    expect(tester.widget<FilledButton>(btn).enabled, isTrue);
  });

  testWidgets('S3 down: first Log text saves locally without an error',
      (tester) async {
    // dart:io in the test body would hang on the fake clock (AGENTS.md),
    // so the temp dir is created inside runAsync.
    final tmpDir = await tester.runAsync(
      () => Directory.systemTemp.createTemp('ql-home-s3down-'),
    );
    final tmp = tmpDir!.path;
    SharedPreferences.setMockInitialValues(<String, Object>{
      'flutter.Directory': tmp,
      'flutter.StorageMode': 's3',
      'flutter.S3AccessKeyId': 'AKIA_TEST',
      'flutter.S3SecretAccessKey': 'secret_test',
    });
    final prefs = PreferencesService();
    final s3Session = S3SessionController(preferences: prefs);
    await s3Session.load();
    final s3 = MemoryS3ObjectClient()
      ..alwaysFail = Exception('network down');
    final active = ActiveNoteStore(
      preferences: prefs,
      session: s3Session,
      s3ClientFactory: (_) => s3,
    );

    addTearDown(() async {
      s3Session.dispose();
      final dir = Directory(tmp);
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    await tester.pumpWidget(
      MaterialApp(
        home: HomeScreen(session: s3Session, activeStore: active),
      ),
    );
    await pumpWithIo(tester);

    await tester.enterText(find.byType(TextField), 'must not be lost');
    await tester.tap(find.widgetWithText(FilledButton, 'Log text'));
    await pumpWithIo(tester);

    // The note is on disk on the very first try — no second log attempt.
    final files = await tester.runAsync(() async =>
      await Directory(tmp)
          .list()
          .where((e) => p.basename(e.path).endsWith('.md'))
          .toList(),
    );
    expect(files, hasLength(1));
    expect(
      await tester.runAsync(() => File(files!.single.path).readAsString()),
      'must not be lost',
    );
    expect(s3.objects, isEmpty);
    expect(s3Session.isDegraded, isTrue);

    // Input was cleared (the note was saved), and no error was shown.
    expect(
      tester
          .widget<TextField>(find.byType(TextField))
          .controller!
          .text,
      isEmpty,
    );
    expect(find.textContaining('Error:'), findsNothing);
    expect(
      find.text('S3 unavailable — the note was saved on this device.'),
      findsOneWidget,
    );

    // Drain the 1-hour degrade expiry Timer (armed by markS3Failed during
    // the tap) so no fake-clock timer is pending when the test ends.
    await tester.pump(const Duration(hours: 1));
  });

  testWidgets('S3 down and local write fails: error shown, input kept',
      (tester) async {
    final tmpDir = await tester.runAsync(
      () => Directory.systemTemp.createTemp('ql-home-bothfail-'),
    );
    final base = tmpDir!.path;
    // Log dir under a regular file: it can never be created.
    await tester.runAsync(
      () => File(p.join(base, 'blocked')).writeAsString('not a directory'),
    );
    SharedPreferences.setMockInitialValues(<String, Object>{
      'flutter.Directory': p.join(base, 'blocked', 'sub'),
      'flutter.StorageMode': 's3',
      'flutter.S3AccessKeyId': 'AKIA_TEST',
      'flutter.S3SecretAccessKey': 'secret_test',
    });
    final prefs = PreferencesService();
    final s3Session = S3SessionController(preferences: prefs);
    await s3Session.load();
    final s3 = MemoryS3ObjectClient()
      ..alwaysFail = Exception('network down');
    final active = ActiveNoteStore(
      preferences: prefs,
      session: s3Session,
      s3ClientFactory: (_) => s3,
    );

    addTearDown(() async {
      s3Session.dispose();
      final dir = Directory(base);
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    await tester.pumpWidget(
      MaterialApp(
        home: HomeScreen(session: s3Session, activeStore: active),
      ),
    );
    await pumpWithIo(tester);

    await tester.enterText(find.byType(TextField), 'still here');
    await tester.tap(find.widgetWithText(FilledButton, 'Log text'));
    await pumpWithIo(tester);

    // Nothing was saved, so the input stays for another attempt and the
    // user sees an error (not the "saved on this device" info).
    expect(
      tester
          .widget<TextField>(find.byType(TextField))
          .controller!
          .text,
      'still here',
    );
    expect(find.textContaining('Error:'), findsOneWidget);
    expect(
      find.text('S3 unavailable — the note was saved on this device.'),
      findsNothing,
    );

    // Drain the pending degrade expiry Timer (see above).
    await tester.pump(const Duration(hours: 1));
  });
}
