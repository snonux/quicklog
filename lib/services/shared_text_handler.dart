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

/// Handles one non-empty cached share. [clearHandled] removes it from the
/// cache — but only while the cache still holds exactly this text.
typedef SharedTextHandle =
    Future<void> Function(String text, Future<void> Function() clearHandled);

/// Serialized intake of the single-slot native share cache (MainActivity).
///
/// [load] is triggered on start-up and on every resume. At most one load runs
/// at a time: triggers that arrive while one is in flight (e.g. leaving and
/// re-entering the app during a slow auto-log save) coalesce into a single
/// follow-up load, which re-reads the cache once the current one is done.
/// Together with compare-and-clear this logs every share exactly once and in
/// order: the in-flight load never re-reads its own share, and it never
/// clears a newer share that overwrote the cache meanwhile — that one is left
/// for the follow-up load. (Two consecutive shares of identical text during
/// one save are indistinguishable in the single-slot cache and log once.)
class SharedTextIntake {
  SharedTextIntake({
    required Future<String?> Function() readCache,
    required Future<void> Function() clearCache,
    required SharedTextHandle handle,
    required void Function(Object error) onError,
  }) : _readCache = readCache,
       _clearCache = clearCache,
       _handle = handle,
       _onError = onError;

  final Future<String?> Function() _readCache;
  final Future<void> Function() _clearCache;
  final SharedTextHandle _handle;
  final void Function(Object error) _onError;

  Future<void>? _inFlight;
  bool _rerun = false;

  /// Loads the cached share, or schedules one follow-up load if a load is
  /// already running. The returned future completes once the cache has been
  /// drained, including any follow-up.
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
        } catch (e) {
          // A failed load must never wedge the intake: report it and let the
          // next (or a pending) load try again.
          _onError(e);
        }
      } while (_rerun);
    } finally {
      _inFlight = null;
    }
  }

  Future<void> _loadOnce() async {
    final text = await _readCache();
    if (text == null || text.isEmpty) return;
    await _handle(text, () => _clearIfUnchanged(text));
  }

  Future<void> _clearIfUnchanged(String handled) async {
    if (await _readCache() == handled) await _clearCache();
  }
}
