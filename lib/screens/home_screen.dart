import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../services/active_note_store.dart';
import '../services/app_version.dart';
import '../services/preferences.dart';
import '../services/s3_session_controller.dart';
import '../services/share_service.dart';
import '../services/shared_text_handler.dart';
import '../widgets/s3_degraded_banner.dart';
import '../widgets/s3_retry.dart';
import 'entry_browser_screen.dart';
import 'preferences_screen.dart';

const int kMaxTextLength = 5000;

class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    this.session,
    this.activeStore,
    this.preferences,
    this.sharedTextCache,
  });

  /// Optional override for tests; defaults to the process-wide session.
  final S3SessionController? session;

  /// Optional override for tests (inject fake S3).
  final ActiveNoteStore? activeStore;

  /// Optional override for tests; defaults to a fresh [PreferencesService].
  /// The running app passes the instance created in `main`.
  final PreferencesService? preferences;

  /// Optional override for tests: the share cache to drain on start-up and
  /// resume. Defaults to the native cache, which exists on Android only.
  final SharedTextCache? sharedTextCache;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  late final PreferencesService _prefs =
      widget.preferences ?? PreferencesService();
  bool _warnShown = false;
  bool _loadingShared = false;
  /// User typed or navigated away while an auto-log share was in flight —
  /// do not moveTaskToBack when that save finishes.
  bool _touchedDuringShareLoad = false;
  /// Last auto-log leave decision in the current intake drain; applied only
  /// after the drain finishes so a queued follow-up share is handled first.
  /// Null means no successful auto-log asked to leave or stay.
  bool? _leaveAfterShareDrain;
  /// True when a success snackbar was skipped because a leave was intended.
  bool _skippedLeaveSnackbar = false;
  Future<void>? _shareDrainInFlight;
  bool _shareDrainNeedsRerun = false;
  bool _logging = false;
  late final SharedTextIntake? _sharedIntake = _createSharedIntake();

  S3SessionController get _session =>
      widget.session ?? S3SessionController.instance;

  ActiveNoteStore get _active => widget.activeStore ?? ActiveNoteStore.instance;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _controller.addListener(_onTextChanged);
    // Session is loaded once in main(); do not re-load here — a racing
    // unawaited load can resurrect a degrade window cleared by retry/mode.
    if (_sharedIntake != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _loadSharedText());
    }
  }

  SharedTextIntake? _createSharedIntake() {
    final cache =
        widget.sharedTextCache ??
        (Platform.isAndroid ? const NativeSharedTextCache() : null);
    if (cache == null) return null;
    return SharedTextIntake(
      cache: cache,
      handle: _handleSharedText,
      onError: _showError,
    );
  }

  /// Drains the share cache in the background; loads are serialized by the
  /// intake, so this is safe to call on every resume.
  void _loadSharedText() {
    final intake = _sharedIntake;
    if (intake == null) return;
    // One drain wrapper at a time — a second resume must not null out
    // _leaveAfterShareDrain while the first drain is still mid-intake.
    if (_shareDrainInFlight != null) {
      _shareDrainNeedsRerun = true;
      unawaited(intake.load());
      return;
    }
    _shareDrainInFlight = _drainSharedText(intake).whenComplete(() {
      _shareDrainInFlight = null;
    });
    unawaited(_shareDrainInFlight!);
  }

  Future<void> _drainSharedText(SharedTextIntake intake) async {
    while (mounted) {
      _shareDrainNeedsRerun = false;
      // A follow-up auto-log during moveTaskToBack may already have set leave;
      // do not clear it or re-load an empty cache — just apply leave again.
      if (_leaveAfterShareDrain != true) {
        _leaveAfterShareDrain = null;
        _skippedLeaveSnackbar = false;
        try {
          await intake.load();
        } catch (e, st) {
          FlutterError.reportError(
            FlutterErrorDetails(exception: e, stack: st),
          );
        }
      }
      final leave = _leaveAfterShareDrain;
      _leaveAfterShareDrain = null;
      if (leave != true) {
        // A later failure may have cancelled leave after an earlier success
        // already skipped its snackbar.
        if (_skippedLeaveSnackbar && mounted) {
          _showInfo('Logged', 'Shared text has been logged.');
        }
        if (_shareDrainNeedsRerun) continue;
        return;
      }
      if (!mounted ||
          _touchedDuringShareLoad ||
          ModalRoute.of(context)?.isCurrent != true) {
        if (mounted) {
          _showInfo('Logged', 'Shared text has been logged.');
        }
        if (_shareDrainNeedsRerun) continue;
        return;
      }
      final moved = await ShareService.moveTaskToBack();
      if (!moved && mounted) {
        _showInfo('Logged', 'Shared text has been logged.');
      }
      // Follow-up share during move set leave again, or a resume needs another
      // intake pass — loop without dropping a pending leave flag.
      if (_leaveAfterShareDrain == true || _shareDrainNeedsRerun) {
        continue;
      }
      return;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller.removeListener(_onTextChanged);
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _loadSharedText();
    }
  }

  void _onTextChanged() {
    final length = _controller.text.length;
    if (_loadingShared) {
      // resetInput at the end of auto-log also fires this; only non-empty
      // text counts as the user taking over the field.
      if (_controller.text.trim().isNotEmpty) {
        _touchedDuringShareLoad = true;
      }
      _warnShown = false;
      setState(() {});
      return;
    }
    if (length > kMaxTextLength && !_warnShown) {
      _warnShown = true;
      _showLengthWarning(length);
    } else if (length <= kMaxTextLength) {
      _warnShown = false;
    }
    setState(() {});
  }

  void _showLengthWarning(int length) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Text Limit'),
        content: Text(
          'Text is getting long ($length chars). Consider logging to avoid '
          'performance issues.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  void _resetInput() {
    _controller.clear();
    _warnShown = false;
    setState(() {});
  }

  Future<void> _logText() async {
    if (_loadingShared) _touchedDuringShareLoad = true;
    if (_logging) return;
    setState(() => _logging = true);
    final text = _controller.text;
    try {
      // S3 (and local, in dual mode) failures are handled inside createNote,
      // so the note is saved on the first try and the submitted input can be
      // cleared without asking the user to retry.
      final result = await _active.createNote(text);
      // A queued IME edit can arrive after the tap but before the disabled
      // field rebuilds. Never erase text that was not part of this save.
      if (_controller.text == text) _resetInput();
      final message = _outcomeMessage(result.outcome);
      if (message != null) {
        _showInfo('Saved', message);
      }
    } catch (e) {
      _showError(e);
    } finally {
      if (mounted) setState(() => _logging = false);
    }
  }

  /// User-visible note for a save that succeeded but did not reach every
  /// backend the mode targets; null when everything landed where expected.
  static String? _outcomeMessage(NoteCreateOutcome outcome) =>
      switch (outcome) {
        NoteCreateOutcome.saved => null,
        NoteCreateOutcome.savedLocalOnly =>
          'S3 unavailable — the note was saved on this device.',
        NoteCreateOutcome.savedS3Only =>
          'The local write failed — the note is in the S3 bucket only.',
        NoteCreateOutcome.savedLocalS3SettingsInvalid =>
          'S3 settings invalid — the note was saved on this device. '
              'Check Preferences.',
      };

  void _showError(Object error) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Error: $error'), backgroundColor: Colors.red),
    );
  }

  void _showInfo(String title, String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  /// Handles one cached share; serialized by [_sharedIntake], so a resume
  /// during a slow auto-log save never logs the same share twice.
  Future<void> _handleSharedText(
    String txt,
    Future<void> Function() clearHandled,
  ) async {
    // Consume before the mounted check so a disposed screen still clears the
    // process-local handoff (cache is left for the next open).
    final shareHandoff = await ShareService.consumeShareHandoff();
    // A follow-up load can outlive the screen; leave the share cached.
    if (!mounted) return;
    _loadingShared = true;
    _touchedDuringShareLoad = false;
    try {
      final dir = await _prefs.directory();
      final autoLog = await _prefs.autoLogSharedText();
      if (!mounted) return;
      await handleSharedTextLoad(
        text: txt,
        autoLog: autoLog,
        dir: dir,
        prefill: (s) {
          _controller.text = s;
          _controller.selection = TextSelection.collapsed(offset: s.length);
        },
        focus: () => _focusNode.requestFocus(),
        resetInput: () {
          if (mounted) _resetInput();
        },
        clearCache: clearHandled,
        logFn: (_, t) async {
          try {
            // Same save path as the main Log text button; an optional custom
            // message tells the handler where the note landed.
            return _outcomeMessage((await _active.createNote(t)).outcome);
          } catch (e) {
            // A failed follow-up must not leave using an earlier leave=true.
            _leaveAfterShareDrain = false;
            rethrow;
          }
        },
        showInfo: _showInfo,
        showError: _showError,
        afterAutoLogSuccess: ({required bool degraded}) async {
          final leave = shouldLeaveAfterShareAutoLog(
            handoff: shareHandoff,
            degraded: degraded,
            touchedDuringLoad: _touchedDuringShareLoad,
            routeIsCurrent: mounted && ModalRoute.of(context)?.isCurrent == true,
          );
          // Last share in the drain wins; moveTaskToBack runs after load().
          _leaveAfterShareDrain = leave;
          if (leave) _skippedLeaveSnackbar = true;
          return leave;
        },
      );
    } finally {
      _loadingShared = false;
      if (mounted) setState(() {});
    }
  }

  Future<void> _openPreferences() async {
    if (_loadingShared) _touchedDuringShareLoad = true;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PreferencesScreen(
          session: _session,
          activeStore: _active,
          preferences: _prefs,
        ),
      ),
    );
  }

  Future<void> _openEntryBrowser() async {
    if (_loadingShared) _touchedDuringShareLoad = true;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => EntryBrowserScreen(
          session: _session,
          activeStore: _active,
          preferences: _prefs,
        ),
      ),
    );
  }

  Future<void> _retryS3() {
    if (_loadingShared) _touchedDuringShareLoad = true;
    return retryS3WithFeedback(context, _session);
  }

  Future<void> _showAbout() async {
    if (_loadingShared) _touchedDuringShareLoad = true;
    // The version comes from the bundled pubspec.yaml, never a literal here:
    // a hard-coded string silently went stale on every release bump.
    String? version;
    try {
      version = await loadAppVersion(DefaultAssetBundle.of(context));
    } catch (e, st) {
      // Omit the version rather than fail to show About, but surface the
      // cause: a missing asset or version: line is a packaging bug.
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: e,
          stack: st,
          library: 'quicklog',
          context: ErrorDescription('while loading the app version for About'),
        ),
      );
    }
    if (!mounted) return;
    showAboutDialog(
      context: context,
      applicationName: 'Quicklog',
      applicationVersion: version,
      applicationIcon: Image.asset('logo-small.png', width: 48, height: 48),
      applicationLegalese:
          'Jot timestamped markdown notes. Optional S3; default is local-only.',
    );
  }

  @override
  Widget build(BuildContext context) {
    final length = _controller.text.length;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Quicklog'),
        actions: [
          IconButton(
            tooltip: 'Browse entries',
            icon: const Icon(Icons.list),
            onPressed: _openEntryBrowser,
          ),
          IconButton(
            tooltip: 'Preferences',
            icon: const Icon(Icons.settings),
            onPressed: _openPreferences,
          ),
          IconButton(
            tooltip: 'About',
            icon: const Icon(Icons.info_outline),
            onPressed: _showAbout,
          ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          S3DegradedBanner(session: _session, onRetry: _retryS3),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: TextField(
                      controller: _controller,
                      focusNode: _focusNode,
                      enabled: !_logging,
                      maxLines: null,
                      expands: true,
                      textAlignVertical: TextAlignVertical.top,
                      decoration: const InputDecoration(
                        hintText: 'Enter text here...',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      FilledButton.icon(
                        onPressed: _logging ? null : _logText,
                        icon: const Icon(Icons.save),
                        label: const Text('Log text'),
                      ),
                      const SizedBox(width: 8),
                      OutlinedButton(
                        onPressed: _logging
                            ? null
                            : () {
                                if (_loadingShared) {
                                  _touchedDuringShareLoad = true;
                                }
                                _resetInput();
                                _focusNode.requestFocus();
                              },
                        child: const Text('Clear'),
                      ),
                      const Spacer(),
                      Text('$length chars'),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
