import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:quicklog/screens/entry_browser_screen.dart';
import 'package:quicklog/screens/home_screen.dart';
import 'package:quicklog/services/active_note_store.dart';
import 'package:quicklog/services/preferences.dart';
import 'package:quicklog/services/s3_session_controller.dart';
import 'package:quicklog/widgets/s3_retry.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'io_pump.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('retryS3WithFeedback', () {
    late S3SessionController session;

    setUp(() async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'flutter.StorageMode': 's3',
      });
      session = S3SessionController();
      await session.load();
    });

    tearDown(() {
      session.dispose();
    });

    testWidgets('reachable retry says S3 is back and clears degrade', (
      tester,
    ) async {
      await session.markS3Failed();
      session.probe = () async {};
      final outcome = await _tapRetry(tester, session);

      expect(outcome.delivered, isTrue);
      expect(outcome.result, S3RetryResult.reachable);
      expect(find.text('S3 reachable again.'), findsOneWidget);
      expect(find.text('S3 still unavailable.'), findsNothing);
      expect(_snackBar(tester).backgroundColor, isNull);
      expect(session.isDegraded, isFalse);
      expect(session.shouldAttemptS3, isTrue);
      await _drainDegradeTimer(tester);
    });

    testWidgets(
      'unavailable retry stays degraded and does not claim S3 is back',
      (tester) async {
        await session.markS3Failed();
        session.probe = () async {
          throw Exception('network down');
        };
        final outcome = await _tapRetry(tester, session);

        expect(outcome.result, S3RetryResult.unavailable);
        expect(find.text('S3 still unavailable.'), findsOneWidget);
        expect(find.text('S3 reachable again.'), findsNothing);
        expect(find.textContaining('Retry failed:'), findsNothing);
        expect(session.isDegraded, isTrue);
        expect(session.shouldAttemptS3, isFalse);
        await _drainDegradeTimer(tester);
      },
    );

    testWidgets('a thrown retry shows the error and leaves S3 degraded', (
      tester,
    ) async {
      final scripted = _ScriptedSession();
      addTearDown(scripted.dispose);
      await scripted.load();
      await scripted.markS3Failed();
      scripted.error = Exception('network down');
      final outcome = await _tapRetry(tester, scripted);

      expect(outcome.delivered, isTrue);
      expect(outcome.result, isNull);
      expect(
        find.text('Retry failed: Exception: network down'),
        findsOneWidget,
      );
      expect(find.text('S3 reachable again.'), findsNothing);
      expect(find.text('S3 still unavailable.'), findsNothing);
      expect(_snackBar(tester).backgroundColor, Colors.red);
      expect(scripted.isDegraded, isTrue);
      expect(scripted.shouldAttemptS3, isFalse);
      await _drainDegradeTimer(tester);
    });

    testWidgets('no probe does not claim a connectivity check', (tester) async {
      await session.markS3Failed();
      expect(session.probe, isNull);
      final outcome = await _tapRetry(tester, session);

      expect(outcome.result, S3RetryResult.armedWithoutProbe);
      expect(
        find.text('S3 retry armed (no connectivity check yet).'),
        findsOneWidget,
      );
      expect(find.text('S3 reachable again.'), findsNothing);
      // The window is cleared optimistically; the wording still must not
      // pretend a probe succeeded.
      expect(session.isDegraded, isFalse);
      await _drainDegradeTimer(tester);
    });

    testWidgets('armedWithoutProbe with a probe attached says reachable', (
      tester,
    ) async {
      final scripted = _ScriptedSession();
      addTearDown(scripted.dispose);
      await scripted.load();
      scripted.probe = () async {};
      scripted.forced = S3RetryResult.armedWithoutProbe;
      final outcome = await _tapRetry(tester, scripted);

      expect(outcome.result, S3RetryResult.armedWithoutProbe);
      expect(find.text('S3 reachable again.'), findsOneWidget);
      expect(
        find.text('S3 retry armed (no connectivity check yet).'),
        findsNothing,
      );
      await _drainDegradeTimer(tester);
    });

    testWidgets('local mode says retry is not applicable', (tester) async {
      await session.setPreferredMode(StorageMode.local);
      final outcome = await _tapRetry(tester, session);

      expect(outcome.result, S3RetryResult.ignored);
      expect(find.text('S3 retry not applicable.'), findsOneWidget);
      expect(find.text('S3 reachable again.'), findsNothing);
      expect(session.isDegraded, isFalse);
      await _drainDegradeTimer(tester);
    });
  });

  group('home screen Retry S3', () {
    late S3SessionController session;

    setUp(() async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'flutter.StorageMode': 's3',
      });
      session = S3SessionController();
      await session.load();
      await session.markS3Failed();
    });

    tearDown(() {
      session.dispose();
    });

    testWidgets('a failed probe keeps the banner and does not say S3 is back', (
      tester,
    ) async {
      session.probe = () async {
        throw Exception('network down');
      };
      await tester.pumpWidget(MaterialApp(home: HomeScreen(session: session)));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Retry S3'));
      await _pumpFeedback(tester);

      expect(find.text('S3 still unavailable.'), findsOneWidget);
      expect(find.text('S3 reachable again.'), findsNothing);
      expect(
        find.textContaining('Using local (S3 unavailable)'),
        findsOneWidget,
      );
      expect(session.isDegraded, isTrue);
      await _drainDegradeTimer(tester);
    });

    testWidgets('a thrown retry shows the error and keeps the banner', (
      tester,
    ) async {
      final scripted = _ScriptedSession();
      addTearDown(scripted.dispose);
      await scripted.load();
      await scripted.markS3Failed();
      scripted.error = Exception('boom');

      await tester.pumpWidget(MaterialApp(home: HomeScreen(session: scripted)));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Retry S3'));
      await _pumpFeedback(tester);

      expect(find.text('Retry failed: Exception: boom'), findsOneWidget);
      expect(find.text('S3 reachable again.'), findsNothing);
      expect(
        find.textContaining('Using local (S3 unavailable)'),
        findsOneWidget,
      );
      expect(_snackBar(tester).backgroundColor, Colors.red);
      expect(scripted.isDegraded, isTrue);
      await _drainDegradeTimer(tester);
    });
  });

  group('entry browser refresh after retry', () {
    late Directory tmp;
    late _ScriptedSession session;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('ql-s3-retry-');
      await File(
        p.join(tmp.path, 'ql-260507-143045.md'),
      ).writeAsString('note body');
      SharedPreferences.setMockInitialValues(<String, Object>{
        'flutter.Directory': tmp.path,
        'flutter.StorageMode': 's3',
      });
      session = _ScriptedSession();
      await session.load();
      await session.markS3Failed();
    });

    tearDown(() async {
      session.dispose();
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    testWidgets('refreshes the list when retry reports S3 reachable', (
      tester,
    ) async {
      session.forced = S3RetryResult.reachable;
      await _pumpBrowser(tester, session);
      expect(find.text('2026-05-07 14:30:45'), findsOneWidget);

      await _writeExtraNote(tester, tmp);
      await tester.tap(find.text('Retry S3'));
      await pumpWithIo(tester);

      expect(find.text('S3 reachable again.'), findsOneWidget);
      expect(find.text('2026-05-07 15:00:00'), findsOneWidget);
      await _drainDegradeTimer(tester);
    });

    testWidgets(
      'refreshes the list when retry arms without a connectivity check',
      (tester) async {
        session.forced = S3RetryResult.armedWithoutProbe;
        await _pumpBrowser(tester, session);
        // First load binds a LIST probe. Drop it so the snackbar is the
        // no-check wording; that result must still re-list.
        session.probe = null;
        expect(session.probe, isNull);
        expect(find.text('2026-05-07 14:30:45'), findsOneWidget);

        await _writeExtraNote(tester, tmp);
        await tester.tap(find.text('Retry S3'));
        await pumpWithIo(tester);

        expect(
          find.text('S3 retry armed (no connectivity check yet).'),
          findsOneWidget,
        );
        expect(find.text('S3 reachable again.'), findsNothing);
        expect(find.text('2026-05-07 15:00:00'), findsOneWidget);
        await _drainDegradeTimer(tester);
      },
    );

    testWidgets('unreachable retry does not refresh or pretend S3 is back', (
      tester,
    ) async {
      session.forced = S3RetryResult.unavailable;
      await _pumpBrowser(tester, session);
      await _writeExtraNote(tester, tmp);
      await tester.tap(find.text('Retry S3'));
      await pumpWithIo(tester);

      expect(find.text('S3 still unavailable.'), findsOneWidget);
      expect(find.text('S3 reachable again.'), findsNothing);
      expect(find.text('2026-05-07 14:30:45'), findsOneWidget);
      expect(find.text('2026-05-07 15:00:00'), findsNothing);
      expect(
        find.textContaining('Using local (S3 unavailable)'),
        findsOneWidget,
      );
      expect(session.isDegraded, isTrue);
      await _drainDegradeTimer(tester);
    });

    testWidgets('a thrown retry shows the error and does not refresh', (
      tester,
    ) async {
      session.error = Exception('network down');
      await _pumpBrowser(tester, session);
      await _writeExtraNote(tester, tmp);
      await tester.tap(find.text('Retry S3'));
      await pumpWithIo(tester);

      expect(
        find.text('Retry failed: Exception: network down'),
        findsOneWidget,
      );
      expect(find.text('S3 reachable again.'), findsNothing);
      expect(_snackBar(tester).backgroundColor, Colors.red);
      expect(find.text('2026-05-07 15:00:00'), findsNothing);
      expect(session.isDegraded, isTrue);
      await _drainDegradeTimer(tester);
    });
  });
}

class _ScriptedSession extends S3SessionController {
  Object? error;
  S3RetryResult? forced;

  @override
  Future<S3RetryResult> retryS3({S3Probe? probe, DateTime? now}) {
    final thrown = error;
    if (thrown != null) return Future<S3RetryResult>.error(thrown);
    final result = forced;
    if (result != null) return Future<S3RetryResult>.value(result);
    return super.retryS3(probe: probe, now: now);
  }
}

class _RetryOutcome {
  const _RetryOutcome({required this.delivered, required this.result});

  final bool delivered;
  final S3RetryResult? result;
}

Future<_RetryOutcome> _tapRetry(
  WidgetTester tester,
  S3SessionController session,
) async {
  S3RetryResult? result;
  var delivered = false;
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              result = await retryS3WithFeedback(context, session);
              delivered = true;
            },
            child: const Text('Retry'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Retry'));
  await _pumpFeedback(tester);
  return _RetryOutcome(delivered: delivered, result: result);
}

SnackBar _snackBar(WidgetTester tester) =>
    tester.widget<SnackBar>(find.byType(SnackBar));

/// Lets the retry future finish without waiting out the snackbar's lifetime.
Future<void> _pumpFeedback(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

/// [S3SessionController.markS3Failed] arms a one-hour timer on the fake clock.
Future<void> _drainDegradeTimer(WidgetTester tester) =>
    tester.pump(const Duration(hours: 1));

Future<void> _pumpBrowser(
  WidgetTester tester,
  S3SessionController session,
) async {
  await tester.pumpWidget(
    MaterialApp(
      home: EntryBrowserScreen(
        session: session,
        activeStore: ActiveNoteStore(session: session),
      ),
    ),
  );
  await pumpWithIo(tester);
}

Future<void> _writeExtraNote(WidgetTester tester, Directory tmp) {
  return tester.runAsync(
    () => File(
      p.join(tmp.path, 'ql-260507-150000.md'),
    ).writeAsString('later note'),
  );
}
