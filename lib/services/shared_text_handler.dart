enum SharedTextLoadMode { prefill, autoLog }

class SharedTextDecision {
  const SharedTextDecision({required this.mode, required this.text, required this.proceed});
  final SharedTextLoadMode mode;
  final String text;
  final bool proceed;
}

SharedTextDecision prepareSharedTextLoad(String text, bool autoLog) {
  if (text.trim().isEmpty) {
    return const SharedTextDecision(mode: SharedTextLoadMode.prefill, text: '', proceed: false);
  }
  return SharedTextDecision(
    mode: autoLog ? SharedTextLoadMode.autoLog : SharedTextLoadMode.prefill,
    text: text,
    proceed: true,
  );
}

typedef LogFn = Future<void> Function(String dir, String text);
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
    try {
      await logFn(dir, decision.text);
    } catch (e) {
      showError(e);
      return;
    }
    showInfo('Logged', 'Shared text has been logged.');
    resetInput();
    await clearCache();
    return;
  }
  prefill(decision.text);
  focus();
  await clearCache();
}
