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
        logFn: (_, _) async => p.logged = true,
        showInfo: p.showInfo,
        showError: p.showError,
      );
      expect(p.logged, true);
      expect(p.info, ['Logged']);
      expect(p.didReset, true);
      expect(p.cleared, true);
      expect(p.errors, isEmpty);
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
        logFn: (_, _) async => p.logged = true,
        showInfo: p.showInfo,
        showError: p.showError,
      );
      expect(p.prefilled, 'note');
      expect(p.focused, true);
      expect(p.cleared, true);
      expect(p.logged, false);
    });
  });
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
    info.add(title);
  }

  void showError(Object e) {
    errors.add(e);
  }
}
