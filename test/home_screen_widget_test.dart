import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:quicklog/screens/home_screen.dart';
import 'package:quicklog/services/active_note_store.dart';
import 'package:quicklog/services/log_service.dart';
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

  testWidgets('repeated taps while an S3 save is pending create one note', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'flutter.StorageMode': 's3',
      'flutter.S3AccessKeyId': 'AKIA_TEST',
      'flutter.S3SecretAccessKey': 'secret_test',
    });
    final prefs = PreferencesService();
    final s3Session = S3SessionController(preferences: prefs);
    await s3Session.load();
    final s3 = _DelayedPutS3ObjectClient();
    final active = ActiveNoteStore(
      preferences: prefs,
      session: s3Session,
      s3ClientFactory: (_) => s3,
    );
    addTearDown(s3Session.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: HomeScreen(session: s3Session, activeStore: active),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'only once');
    final button = find.widgetWithText(FilledButton, 'Log text');
    await tester.tap(button);
    // Tap again before a frame rebuilds the disabled button. The handler's
    // synchronous guard must reject this invocation as well.
    await tester.tap(button);
    // Simulate an IME edit that was already queued before the field became
    // disabled. It was not part of the submitted snapshot and must survive.
    tester.widget<TextField>(find.byType(TextField)).controller!.text =
        'typed after tap';
    await tester.pump();

    expect(s3.putCalls, 1);
    expect(tester.widget<FilledButton>(button).enabled, isFalse);

    s3.finishPut();
    await tester.pumpAndSettle();

    expect(s3.objects, hasLength(1));
    expect(tester.widget<FilledButton>(button).enabled, isTrue);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'typed after tap',
    );
  });

  testWidgets('a failed pending save unlocks controls and allows retry', (
    tester,
  ) async {
    final active = _DelayedFailingActiveNoteStore(session);
    await tester.pumpWidget(
      MaterialApp(
        home: HomeScreen(session: session, activeStore: active),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'keep for retry');
    final logButton = find.widgetWithText(FilledButton, 'Log text');
    final clearButton = find.widgetWithText(OutlinedButton, 'Clear');
    await tester.tap(logButton);
    await tester.tap(logButton);
    await tester.pump();

    expect(active.createCalls, 1);
    expect(tester.widget<FilledButton>(logButton).enabled, isFalse);
    expect(tester.widget<OutlinedButton>(clearButton).enabled, isFalse);
    expect(tester.widget<TextField>(find.byType(TextField)).enabled, isFalse);

    active.fail(0);
    await tester.pumpAndSettle();

    expect(tester.widget<FilledButton>(logButton).enabled, isTrue);
    expect(tester.widget<OutlinedButton>(clearButton).enabled, isTrue);
    expect(tester.widget<TextField>(find.byType(TextField)).enabled, isTrue);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'keep for retry',
    );
    expect(find.textContaining('Error:'), findsOneWidget);

    // Let the error snackbar clear so it no longer covers the bottom action.
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    await tester.tap(logButton);
    await tester.pump();
    expect(active.createCalls, 2);
    active.succeed(1);
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(logButton).enabled, isTrue);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      isEmpty,
    );
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

  testWidgets('dual mode, S3 down: first Log text still saves locally',
      (tester) async {
    final tmpDir = await tester.runAsync(
      () => Directory.systemTemp.createTemp('ql-home-both-'),
    );
    final base = tmpDir!.path;
    SharedPreferences.setMockInitialValues(<String, Object>{
      'flutter.Directory': base,
      'flutter.StorageMode': 'both',
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

    await tester.enterText(find.byType(TextField), 'dual down');
    await tester.tap(find.widgetWithText(FilledButton, 'Log text'));
    await pumpWithIo(tester);

    final files = await tester.runAsync(() async =>
      await Directory(base)
          .list()
          .where((e) => p.basename(e.path).endsWith('.md'))
          .toList(),
    );
    expect(files, hasLength(1));
    expect(
      await tester.runAsync(() => File(files!.single.path).readAsString()),
      'dual down',
    );
    expect(s3.objects, isEmpty);
    expect(s3Session.isDegraded, isTrue);

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
    // The dual-mode banner says local is still the primary target.
    expect(
      find.textContaining('notes are still being saved locally'),
      findsOneWidget,
    );

    // Drain the pending degrade expiry Timer (see above).
    await tester.pump(const Duration(hours: 1));
  });

  testWidgets('dual mode, local write fails: S3-only outcome reported',
      (tester) async {
    final tmpDir = await tester.runAsync(
      () => Directory.systemTemp.createTemp('ql-home-s3only-'),
    );
    final base = tmpDir!.path;
    // Log dir under a regular file: the local write can never succeed.
    await tester.runAsync(
      () => File(p.join(base, 'blocked')).writeAsString('not a directory'),
    );
    SharedPreferences.setMockInitialValues(<String, Object>{
      'flutter.Directory': p.join(base, 'blocked', 'sub'),
      'flutter.StorageMode': 'both',
      'flutter.S3AccessKeyId': 'AKIA_TEST',
      'flutter.S3SecretAccessKey': 'secret_test',
    });
    final prefs = PreferencesService();
    final s3Session = S3SessionController(preferences: prefs);
    await s3Session.load();
    final s3 = MemoryS3ObjectClient();
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

    await tester.enterText(find.byType(TextField), 'bucket copy');
    await tester.tap(find.widgetWithText(FilledButton, 'Log text'));
    await pumpWithIo(tester);

    // The note is safe in the bucket; this is reported, not an error, so
    // the input is cleared and a retry cannot duplicate it.
    expect(s3.objects, hasLength(1));
    expect(
      tester
          .widget<TextField>(find.byType(TextField))
          .controller!
          .text,
      isEmpty,
    );
    expect(find.textContaining('Error:'), findsNothing);
    expect(
      find.text('The local write failed — the note is in the S3 bucket only.'),
      findsOneWidget,
    );

    // No degrade was armed (S3 is healthy), but the snackbar's display
    // timer is still pending on the fake clock — pump past it.
    await tester.pump(const Duration(seconds: 5));
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

class _DelayedPutS3ObjectClient extends MemoryS3ObjectClient {
  final Completer<void> _putCompleter = Completer<void>();
  int putCalls = 0;

  @override
  Future<void> putObject(
    String key,
    List<int> bytes, {
    String contentType = 'text/markdown',
  }) async {
    putCalls++;
    await _putCompleter.future;
    await super.putObject(key, bytes, contentType: contentType);
  }

  void finishPut() => _putCompleter.complete();
}

class _DelayedFailingActiveNoteStore extends ActiveNoteStore {
  _DelayedFailingActiveNoteStore(S3SessionController session)
    : super(session: session);

  final List<Completer<NoteCreateResult>> _requests = [];

  int get createCalls => _requests.length;

  @override
  Future<NoteCreateResult> createNote(String text, {DateTime? now}) {
    final request = Completer<NoteCreateResult>();
    _requests.add(request);
    return request.future;
  }

  void fail(int index) =>
      _requests[index].completeError(Exception('save failed'));

  void succeed(int index) => _requests[index].complete((
    entry: LogEntry(id: 'ql-260101-000000.md', timestamp: DateTime(2026, 1, 1)),
    outcome: NoteCreateOutcome.saved,
  ));
}
