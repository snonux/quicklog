import 'package:flutter/foundation.dart';

import 'share_service.dart';

enum SharedTextLoadMode { prefill, autoLog }

class SharedTextDecision {
  const SharedTextDecision({
    required this.mode,
    required this.text,
    required this.proceed,
  });
  final SharedTextLoadMode mode;
  final String text;
  final bool proceed;
}

SharedTextDecision prepareSharedTextLoad(String text, bool autoLog) {
  if (text.trim().isEmpty) {
    return const SharedTextDecision(
      mode: SharedTextLoadMode.prefill,
      text: '',
      proceed: false,
    );
  }
  return SharedTextDecision(
    mode: autoLog ? SharedTextLoadMode.autoLog : SharedTextLoadMode.prefill,
    text: text,
    proceed: true,
  );
}

/// Logs [text] into [dir]. Returns an optional custom success message
/// (e.g. where the note landed when S3 was unavailable); null keeps the
/// default "logged" message.
typedef LogFn = Future<String?> Function(String dir, String text);
typedef ShowInfo = void Function(String title, String message);
typedef ShowError = void Function(Object error);

Future<void> handleSharedTextLoad({
  required String text,
  required bool autoLog,
  required String dir,
  required void Function(String) prefill,
  required void Function() focus,
  required void Function() resetInput,
  required Future<void> Function() clearCache,
  required LogFn logFn,
  required ShowInfo showInfo,
  required ShowError showError,
}) async {
  final decision = prepareSharedTextLoad(text, autoLog);
  if (!decision.proceed) {
    await clearCache();
    return;
  }
  if (decision.mode == SharedTextLoadMode.autoLog) {
    String? customMessage;
    try {
      customMessage = await logFn(dir, decision.text);
    } catch (e) {
      showError(e);
      return;
    }
    showInfo('Logged', customMessage ?? 'Shared text has been logged.');
    resetInput();
    await clearCache();
    return;
  }
  prefill(decision.text);
  focus();
  await clearCache();
}

/// The single-slot native share cache (cacheDir/quicklog-shared.txt, written
/// by MainActivity whenever text is shared to the app).
abstract interface class SharedTextCache {
  Future<String?> read();
  Future<void> clear();
}

/// [SharedTextCache] backed by the Android share channel ([ShareService]).
class NativeSharedTextCache implements SharedTextCache {
  const NativeSharedTextCache();

  @override
  Future<String?> read() => ShareService.readSharedTextFromCache();

  @override
  Future<void> clear() => ShareService.clearSharedTextCache();
}

/// Handles one non-empty cached share. [clearHandled] removes it from the
/// cache — but only while the cache still holds exactly this text. It never
/// throws: clearing is best effort once the share has been handled.
typedef SharedTextHandle =
    Future<void> Function(String text, Future<void> Function() clearHandled);

/// Serialized intake of the single-slot native share cache.
///
/// [load] is triggered on start-up and on every resume. At most one load runs
/// at a time: triggers that arrive while one is in flight (e.g. leaving and
/// re-entering the app during a slow auto-log save) coalesce into a single
/// follow-up load, which re-reads the cache once the current one is done. So
/// the in-flight load never re-reads (and re-logs) its own share.
///
/// After handling a share the cache is cleared only if it still holds that
/// text (compare-and-clear), so a newer share that overwrote the cache during
/// a slow save is left for the follow-up load and logged after the first.
///
/// Residual race: the compare and the clear are two separate platform calls
/// (read, then delete). A share written by MainActivity between those two
/// calls is still deleted unseen. This narrows the window from "the whole
/// save" to two back-to-back channel round trips, but does not eliminate it;
/// that needs an atomic compare-and-delete on the native side. Also, two
/// consecutive shares of identical text cannot be told apart in the single
/// slot and are logged once.
class SharedTextIntake {
  SharedTextIntake({
    required SharedTextCache cache,
    required SharedTextHandle handle,
    required void Function(Object error) onError,
  }) : _cache = cache,
       _handle = handle,
       _onError = onError;

  final SharedTextCache _cache;
  final SharedTextHandle _handle;
  final void Function(Object error) _onError;

  Future<void>? _inFlight;
  bool _rerun = false;

  /// Text that was handled but could not be cleared from the cache; it is
  /// not handled again while it is still what the cache holds.
  String? _handledNotCleared;

  /// Loads the cached share, or schedules one follow-up load if a load is
  /// already running. The returned future completes once the cache has been
  /// drained, including any follow-up. It never completes with an error.
  Future<void> load() {
    final inFlight = _inFlight;
    if (inFlight != null) {
      _rerun = true;
      return inFlight;
    }
    return _inFlight = _drain();
  }

  Future<void> _drain() async {
    try {
      do {
        _rerun = false;
        try {
          await _loadOnce();
        } catch (e, st) {
          // A failed load must never wedge the intake: report it and let the
          // next (or a pending) load try again.
          _reportFailure(e, st);
        }
      } while (_rerun);
    } finally {
      _inFlight = null;
    }
  }

  Future<void> _loadOnce() async {
    final text = await _cache.read();
    if (text == null || text.isEmpty) {
      _handledNotCleared = null;
      return;
    }
    if (text == _handledNotCleared) {
      // Already logged; only the earlier clear failed. Retry that instead of
      // logging the share a second time.
      await _clearIfUnchanged(text);
      return;
    }
    _handledNotCleared = null;
    await _handle(text, () => _clearIfUnchanged(text));
  }

  Future<void> _clearIfUnchanged(String handled) async {
    try {
      if (await _cache.read() == handled) await _cache.clear();
      _handledNotCleared = null;
    } catch (e) {
      // The share is already handled; a failed clear is not a failed load.
      // Log it and remember the text so the next load does not re-log it.
      _handledNotCleared = handled;
      debugPrint('quicklog: could not clear the shared-text cache: $e');
    }
  }

  /// Expected failures (I/O, channel) go to [_onError] for the user;
  /// programming errors go to [FlutterError.reportError] instead.
  void _reportFailure(Object error, StackTrace stack) {
    if (error is Error) {
      _reportError(error, stack, 'while loading shared text');
      return;
    }
    try {
      _onError(error);
    } catch (e, st) {
      _reportError(e, st, 'while reporting a shared-text load failure');
    }
  }

  static void _reportError(Object error, StackTrace stack, String context) {
    FlutterError.reportError(
      FlutterErrorDetails(
        exception: error,
        stack: stack,
        library: 'quicklog',
        context: ErrorDescription(context),
      ),
    );
  }
}
