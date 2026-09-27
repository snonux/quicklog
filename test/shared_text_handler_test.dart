import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:quicklog/services/shared_text_handler.dart';

void main() {
  group('prepareSharedTextLoad', () {
    test('rejects whitespace-only input', () {
      final d = prepareSharedTextLoad('   \n\t', false);
      expect(d.proceed, isFalse);
    });

    test('returns prefill mode when autoLog is false', () {
      final d = prepareSharedTextLoad('hello', false);
      expect(d.proceed, isTrue);
      expect(d.mode, SharedTextLoadMode.prefill);
      expect(d.text, 'hello');
    });

    test('returns autoLog mode when autoLog is true', () {
      final d = prepareSharedTextLoad('hello', true);
      expect(d.proceed, isTrue);
      expect(d.mode, SharedTextLoadMode.autoLog);
    });

    test('does not truncate long input', () {
      final big = 'x' * 10000;
      final d = prepareSharedTextLoad(big, true);
      expect(d.text.length, 10000);
    });
  });

  group('handleSharedTextLoad', () {
    late _Probe p;
    setUp(() => p = _Probe());

    test('autoLog success: logs, shows info, resets, clears cache', () async {
      await handleSharedTextLoad(
        text: 'note',
        autoLog: true,
        dir: '/tmp',
        prefill: p.prefill,
        focus: p.focus,
        resetInput: p.resetInput,
        clearCache: p.clearCache,
        logFn: (_, _) async {
          p.logged = true;
          return null;
        },
        showInfo: p.showInfo,
        showError: p.showError,
      );
      expect(p.logged, true);
      expect(p.info, ['Shared text has been logged.']);
      expect(p.didReset, true);
      expect(p.cleared, true);
      expect(p.errors, isEmpty);
    });

    test('autoLog uses the custom message when logFn returns one', () async {
      await handleSharedTextLoad(
        text: 'note',
        autoLog: true,
        dir: '/tmp',
        prefill: p.prefill,
        focus: p.focus,
        resetInput: p.resetInput,
        clearCache: p.clearCache,
        logFn: (_, _) async {
          p.logged = true;
          return 'Shared text has been logged to this device (S3 unavailable).';
        },
        showInfo: p.showInfo,
        showError: p.showError,
      );
      expect(p.logged, true);
      expect(p.info, [
        'Shared text has been logged to this device (S3 unavailable).',
      ]);
      expect(p.didReset, true);
      expect(p.cleared, true);
    });

    test('autoLog failure: shows error, keeps cache, does not reset', () async {
      await handleSharedTextLoad(
        text: 'note',
        autoLog: true,
        dir: '/tmp',
        prefill: p.prefill,
        focus: p.focus,
        resetInput: p.resetInput,
        clearCache: p.clearCache,
        logFn: (_, _) async => throw Exception('boom'),
        showInfo: p.showInfo,
        showError: p.showError,
      );
      expect(p.errors.length, 1);
      expect(p.cleared, false);
      expect(p.didReset, false);
    });

    test('empty text: clears cache and skips everything else', () async {
      await handleSharedTextLoad(
        text: '   ',
        autoLog: true,
        dir: '/tmp',
        prefill: p.prefill,
        focus: p.focus,
        resetInput: p.resetInput,
        clearCache: p.clearCache,
        logFn: (_, _) async {
          p.logged = true;
          return null;
        },
        showInfo: p.showInfo,
        showError: p.showError,
      );
      expect(p.logged, false);
      expect(p.cleared, true);
      expect(p.didReset, false);
      expect(p.prefilled, isNull);
    });

    test('prefill mode: prefills + focuses + clears cache, no log', () async {
      await handleSharedTextLoad(
        text: 'note',
        autoLog: false,
        dir: '/tmp',
        prefill: p.prefill,
        focus: p.focus,
        resetInput: p.resetInput,
        clearCache: p.clearCache,
        logFn: (_, _) async {
          p.logged = true;
          return null;
        },
        showInfo: p.showInfo,
        showError: p.showError,
      );
      expect(p.prefilled, 'note');
      expect(p.focused, true);
      expect(p.cleared, true);
      expect(p.logged, false);
    });
  });

  group('SharedTextIntake', () {
    late _FakeShareCache cache;
    late _SlowStore store;
    late List<Object> errors;
    late SharedTextIntake intake;

    setUp(() {
      cache = _FakeShareCache();
      store = _SlowStore();
      errors = [];
      // Mirrors HomeScreen: every cached share goes through the auto-log
      // path of handleSharedTextLoad, backed by the (slow) store.
      intake = SharedTextIntake(
        readCache: cache.read,
        clearCache: cache.clear,
        handle: (text, clearHandled) => handleSharedTextLoad(
          text: text,
          autoLog: true,
          dir: '/notes',
          prefill: (_) {},
          focus: () {},
          resetInput: () {},
          clearCache: clearHandled,
          logFn: (_, t) async {
            await store.createNote(t);
            return null;
          },
          showInfo: (_, _) {},
          showError: errors.add,
        ),
        onError: errors.add,
      );
    });

    test('a resume during a slow save does not log the share twice', () async {
      cache.share('first');
      final start = intake.load();
      await store.started(1);

      // Leave and re-enter the app while the save is still in flight.
      final resume1 = intake.load();
      final resume2 = intake.load();
      await pumpEventQueue();
      expect(store.attempts, ['first']);

      store.completeNext();
      await Future.wait([start, resume1, resume2]);

      expect(store.saved, ['first']);
      expect(store.attempts, ['first']);
      expect(cache.content, isNull);
      expect(errors, isEmpty);
    });

    test('a second share during a save is logged after the first', () async {
      cache.share('first');
      final start = intake.load();
      await store.started(1);

      // The new share overwrites the single-slot cache, then resumes the app.
      cache.share('second');
      final resume = intake.load();

      store.completeNext();
      await store.started(2);
      expect(store.saved, ['first']);
      // The first save must not have cleared the newer share.
      expect(cache.content, 'second');

      store.completeNext();
      await Future.wait([start, resume]);

      expect(store.saved, ['first', 'second']);
      expect(cache.content, isNull);
      expect(errors, isEmpty);
    });

    test('a failed save does not wedge the intake', () async {
      cache.share('first');
      final start = intake.load();
      await store.started(1);
      final resume = intake.load();

      store.failNext(Exception('S3 timeout'));
      // The queued follow-up still runs and retries the kept share.
      await store.started(2);
      store.completeNext();
      await Future.wait([start, resume]);

      expect(errors, hasLength(1));
      expect(store.saved, ['first']);
      expect(cache.content, isNull);

      // And the intake accepts new loads afterwards.
      cache.share('later');
      final next = intake.load();
      await store.started(3);
      store.completeNext();
      await next;
      expect(store.saved, ['first', 'later']);
    });

    test('a throwing load is reported and the next load still runs', () async {
      cache.failReads = true;
      await intake.load();
      expect(errors, hasLength(1));

      cache.failReads = false;
      cache.share('note');
      final next = intake.load();
      await store.started(1);
      store.completeNext();
      await next;
      expect(store.saved, ['note']);
    });

    test('an empty share is cleared without logging', () async {
      cache.share('   ');
      await intake.load();
      expect(store.attempts, isEmpty);
      expect(cache.content, isNull);
      expect(errors, isEmpty);
    });

    test('an empty cache does nothing', () async {
      await intake.load();
      expect(store.attempts, isEmpty);
      expect(cache.clears, 0);
      expect(errors, isEmpty);
    });
  });
}

/// In-memory stand-in for the single-slot native share cache.
class _FakeShareCache {
  String? content;
  int clears = 0;
  bool failReads = false;

  void share(String text) => content = text;

  Future<String?> read() async {
    if (failReads) throw Exception('channel down');
    return content;
  }

  Future<void> clear() async {
    clears++;
    content = null;
  }
}

/// Note store whose saves block until the test completes or fails them.
class _SlowStore {
  final List<String> attempts = [];
  final List<String> saved = [];
  final List<Completer<void>> _pending = [];
  final StreamController<void> _startedEvents = StreamController.broadcast();

  Future<void> createNote(String text) async {
    attempts.add(text);
    final gate = Completer<void>();
    _pending.add(gate);
    _startedEvents.add(null);
    await gate.future;
    saved.add(text);
  }

  /// Completes once [count] saves have started in total.
  Future<void> started(int count) async {
    while (attempts.length < count) {
      await _startedEvents.stream.first;
    }
  }

  void completeNext() => _pending.removeAt(0).complete();

  void failNext(Object error) => _pending.removeAt(0).completeError(error);
}

class _Probe {
  String? prefilled;
  bool focused = false;
  bool didReset = false;
  bool cleared = false;
  bool logged = false;
  final List<String> info = [];
  final List<Object> errors = [];

  void prefill(String s) {
    prefilled = s;
  }

  void focus() {
    focused = true;
  }

  void resetInput() {
    didReset = true;
  }

  Future<void> clearCache() async {
    cleared = true;
  }

  void showInfo(String title, String msg) {
    info.add(msg);
  }

  void showError(Object e) {
    errors.add(e);
  }
}
