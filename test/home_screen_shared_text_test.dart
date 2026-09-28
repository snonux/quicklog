import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quicklog/screens/home_screen.dart';
import 'package:quicklog/services/active_note_store.dart';
import 'package:quicklog/services/log_service.dart';
import 'package:quicklog/services/s3_session_controller.dart';
import 'package:quicklog/services/shared_text_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late S3SessionController session;
  late _FakeShareCache cache;
  late _SlowActiveNoteStore store;

  Future<void> setPrefs({Object autoLog = true}) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'flutter.Directory': '/nonexistent/quicklog-test',
      'flutter.AutoLogSharedText': autoLog,
    });
    session = S3SessionController();
    await session.load();
  }

  setUp(() async {
    await setPrefs();
    cache = _FakeShareCache();
  });

  tearDown(() => session.dispose());

  Future<void> pumpHome(WidgetTester tester) async {
    store = _SlowActiveNoteStore(session);
    await tester.pumpWidget(
      MaterialApp(
        home: HomeScreen(
          session: session,
          activeStore: store,
          sharedTextCache: cache,
        ),
      ),
    );
    // The first frame's post-frame callback starts the intake.
    await tester.pump();
  }

  /// Typing past the length limit shows a warning — unless the screen still
  /// believes a shared text is being loaded, which suppresses it.
  Future<void> expectLengthWarningShown(WidgetTester tester) async {
    await tester.enterText(find.byType(TextField), 'x' * (kMaxTextLength + 1));
    await tester.pump();
    expect(find.text('Text Limit'), findsOneWidget);
  }

  testWidgets('a resume during a slow auto-log save logs the share once', (
    tester,
  ) async {
    cache.content = 'shared';
    await pumpHome(tester);
    expect(store.texts, ['shared']);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(store.texts, ['shared']);

    store.succeed(0);
    await tester.pumpAndSettle();
    expect(store.texts, ['shared']);
    expect(cache.content, isNull);
  });

  testWidgets('a share queued behind a save stays cached once disposed', (
    tester,
  ) async {
    cache.content = 'first';
    await pumpHome(tester);

    // A second share arrives and resumes the app during the slow save; then
    // the screen goes away before the follow-up load can handle it.
    cache.content = 'second';
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await tester.pumpWidget(const SizedBox());

    store.succeed(0);
    await tester.pump();

    expect(store.texts, ['first']);
    expect(cache.content, 'second');
    expect(tester.takeException(), isNull);
  });

  testWidgets('a save finishing after dispose calls no setState', (
    tester,
  ) async {
    cache.content = 'shared';
    await pumpHome(tester);
    await tester.pumpWidget(const SizedBox());

    store.succeed(0);
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(cache.content, isNull);
  });

  testWidgets('a failed save resets the shared-load state', (tester) async {
    cache.content = 'shared';
    await pumpHome(tester);

    store.fail(0);
    await tester.pumpAndSettle();

    expect(find.textContaining('save failed'), findsOneWidget);
    expect(cache.content, 'shared');
    await expectLengthWarningShown(tester);
  });

  testWidgets('a throwing preference read resets the shared-load state', (
    tester,
  ) async {
    // A mistyped stored value makes the auto-log lookup throw a TypeError.
    await setPrefs(autoLog: 'yes');
    cache.content = 'shared';
    await pumpHome(tester);

    expect(tester.takeException(), isA<TypeError>());
    expect(store.texts, isEmpty);
    expect(cache.content, 'shared');
    await expectLengthWarningShown(tester);
  });
}

class _FakeShareCache implements SharedTextCache {
  String? content;

  @override
  Future<String?> read() async => content;

  @override
  Future<bool> clearIfEquals(String expected) async {
    if (content != expected) return false;
    content = null;
    return true;
  }
}

/// Note store whose saves block until the test completes or fails them.
class _SlowActiveNoteStore extends ActiveNoteStore {
  _SlowActiveNoteStore(S3SessionController session) : super(session: session);

  final List<String> texts = [];
  final List<Completer<NoteCreateResult>> _requests = [];

  @override
  Future<NoteCreateResult> createNote(String text, {DateTime? now}) {
    texts.add(text);
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
