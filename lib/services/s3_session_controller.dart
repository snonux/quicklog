import 'package:flutter/foundation.dart';

import 'log_service.dart';
import 'preferences.dart';

/// How long a failed S3 preference stays on local before auto-retry is allowed.
const Duration kS3DegradeDuration = Duration(hours: 1);

/// Cheap connectivity check used by [S3SessionController.retryS3].
/// Injected so unit tests (and later the real S3 client) can stub LIST/HEAD
/// without the controller owning network code.
typedef S3Probe = Future<void> Function();

/// Resolves preferred [StorageMode] against a persisted degrade window.
///
/// When the user prefers S3 and an I/O failure is recorded, the app falls back
/// to local until [retryS3] succeeds, the process loads after
/// [kS3DegradeDuration], or the clock passes [degradedUntil] mid-session.
class S3SessionController extends ChangeNotifier {
  S3SessionController({
    PreferencesService? preferences,
    DateTime Function()? clock,
    this.probe,
  })  : _prefs = preferences ?? PreferencesService(),
        _clock = clock ?? DateTime.now;

  static final S3SessionController instance = S3SessionController();

  final PreferencesService _prefs;
  final DateTime Function() _clock;

  /// Optional default probe for [retryS3] when no argument is passed.
  S3Probe? probe;

  StorageMode preferredMode = StorageMode.local;
  DateTime? degradedUntil;
  bool loaded = false;

  /// Preferred S3 and still inside the degrade window.
  bool get isDegraded {
    if (preferredMode != StorageMode.s3) return false;
    final until = degradedUntil;
    if (until == null) return false;
    return _clock().isBefore(until);
  }

  /// True when I/O should go to the local store (preferred local, or S3
  /// preferred but currently degraded).
  bool get usesLocalFallback =>
      preferredMode == StorageMode.local || isDegraded;

  /// True when preferred mode is S3 and the degrade window is not active.
  bool get shouldAttemptS3 =>
      preferredMode == StorageMode.s3 && !isDegraded;

  /// Pick the active [NoteStore]. [s3] is optional until S3NoteStore lands;
  /// when omitted, local is used even if [shouldAttemptS3] is true.
  NoteStore resolveStore({
    required NoteStore Function() local,
    NoteStore Function()? s3,
  }) {
    if (shouldAttemptS3 && s3 != null) return s3();
    return local();
  }

  /// Load persisted mode / degrade window. Clears an expired window so a cold
  /// start (or a long-lived process that re-loads) can attempt S3 again.
  Future<void> load({DateTime? now}) async {
    preferredMode = await _prefs.storageMode();
    degradedUntil = await _prefs.degradedUntil();
    await _clearIfExpired(now: now);
    loaded = true;
    notifyListeners();
  }

  Future<void> setPreferredMode(StorageMode mode) async {
    preferredMode = mode;
    await _prefs.setStorageMode(mode);
    if (mode == StorageMode.local) {
      // Local-only: degrade state is irrelevant; drop it so a later switch
      // back to S3 starts clean unless a new failure is recorded.
      await _clearDegraded();
    }
    notifyListeners();
  }

  /// Record an S3 I/O failure: fall back to local for [kS3DegradeDuration].
  Future<void> markS3Failed({DateTime? now}) async {
    final t = now ?? _clock();
    degradedUntil = t.add(kS3DegradeDuration);
    await _prefs.setDegradedUntil(degradedUntil);
    notifyListeners();
  }

  /// Clear the degrade window and run [probe] (or [this.probe]).
  /// Success keeps S3 active; failure re-arms the 1h window.
  Future<bool> retryS3({S3Probe? probe, DateTime? now}) async {
    if (preferredMode != StorageMode.s3) return false;
    final run = probe ?? this.probe;
    if (run == null) {
      throw StateError('S3 probe not configured');
    }
    await _clearDegraded();
    notifyListeners();
    try {
      await run();
      return true;
    } catch (_) {
      await markS3Failed(now: now ?? _clock());
      return false;
    }
  }

  Future<void> _clearIfExpired({DateTime? now}) async {
    final until = degradedUntil;
    if (until == null) return;
    final t = now ?? _clock();
    if (!t.isBefore(until)) {
      await _clearDegraded();
    }
  }

  Future<void> _clearDegraded() async {
    if (degradedUntil == null) {
      await _prefs.setDegradedUntil(null);
      return;
    }
    degradedUntil = null;
    await _prefs.setDegradedUntil(null);
  }
}
