import 'dart:async';

import 'package:flutter/foundation.dart';

import 'log_service.dart';
import 'preferences.dart';

/// How long a failed S3 preference stays on local before auto-retry is allowed.
const Duration kS3DegradeDuration = Duration(hours: 1);

/// Cheap connectivity check used by [S3SessionController.retryS3].
/// Injected so unit tests (and later the real S3 client) can stub LIST/HEAD
/// without the controller owning network code.
typedef S3Probe = Future<void> Function();

/// Outcome of [S3SessionController.retryS3].
enum S3RetryResult {
  /// Preferred mode is not S3; nothing changed.
  ignored,

  /// Probe succeeded; degrade cleared.
  reachable,

  /// Probe failed; degrade window re-armed.
  unavailable,

  /// No probe configured yet; degrade cleared optimistically (no connectivity
  /// check was performed).
  armedWithoutProbe,
}

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
  /// Left injectable (not private) so tests / S3NoteStore can wire it later.
  S3Probe? probe;

  StorageMode _preferredMode = StorageMode.local;
  DateTime? _degradedUntil;
  bool _loaded = false;
  Timer? _expiryTimer;
  /// Bumped whenever degrade state is intentionally rewritten so an in-flight
  /// async prefs clear from expiry cannot wipe a newer window.
  int _degradeGeneration = 0;
  bool _disposed = false;

  StorageMode get preferredMode => _preferredMode;
  DateTime? get degradedUntil => _degradedUntil;
  bool get loaded => _loaded;

  /// Preferred S3 and still inside the degrade window.
  ///
  /// Reading after the window elapses clears persistence and notifies listeners
  /// so the banner can drop without a cold start (also covered by [_expiryTimer]).
  bool get isDegraded {
    _syncExpiryOnAccess();
    if (_preferredMode != StorageMode.s3) return false;
    final until = _degradedUntil;
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
  ///
  /// Idempotent: once [loaded], subsequent calls only re-check expiry and do
  /// not re-read prefs (avoids resurrecting a window cleared mid-session).
  Future<void> load({DateTime? now}) async {
    if (_loaded) {
      await _clearIfExpired(now: now);
      return;
    }
    _preferredMode = await _prefs.storageMode();
    _degradedUntil = await _prefs.degradedUntil();
    await _clearIfExpired(now: now);
    _loaded = true;
    _scheduleExpiryTimer();
    notifyListeners();
  }

  Future<void> setPreferredMode(StorageMode mode) async {
    _preferredMode = mode;
    await _prefs.setStorageMode(mode);
    if (mode == StorageMode.local) {
      // Local-only: degrade state is irrelevant; drop it so a later switch
      // back to S3 starts clean unless a new failure is recorded.
      await _clearDegraded();
    }
    notifyListeners();
  }

  /// Record an S3 I/O failure: fall back to local for [kS3DegradeDuration].
  /// No-op when preferred mode is local (degrade is meaningless there).
  Future<void> markS3Failed({DateTime? now}) async {
    if (_preferredMode != StorageMode.s3) return;
    final t = now ?? _clock();
    _degradeGeneration++;
    _degradedUntil = t.add(kS3DegradeDuration);
    await _prefs.setDegradedUntil(_degradedUntil);
    _scheduleExpiryTimer();
    notifyListeners();
  }

  /// Clear the degrade window and run [probe] (or [this.probe]).
  ///
  /// When no probe is configured yet (S3NoteStore not landed), clears the
  /// degrade window optimistically and returns [S3RetryResult.armedWithoutProbe]
  /// so the UI does not claim reachability.
  Future<S3RetryResult> retryS3({S3Probe? probe, DateTime? now}) async {
    if (_preferredMode != StorageMode.s3) return S3RetryResult.ignored;
    final run = probe ?? this.probe;
    await _clearDegraded();
    notifyListeners();
    if (run == null) {
      return S3RetryResult.armedWithoutProbe;
    }
    try {
      await run();
      return S3RetryResult.reachable;
    } catch (_) {
      await markS3Failed(now: now ?? _clock());
      return S3RetryResult.unavailable;
    }
  }

  /// If the clock has passed [degradedUntil], clear memory immediately and
  /// schedule prefs clear + [notifyListeners] (so ListenableBuilder rebuilds).
  ///
  /// Uses [_degradeGeneration] so a concurrent [markS3Failed] / [retryS3]
  /// cannot have its prefs write wiped by this deferred clear.
  void _syncExpiryOnAccess() {
    final until = _degradedUntil;
    if (until == null) return;
    if (_clock().isBefore(until)) return;
    final generation = _degradeGeneration;
    _degradedUntil = null;
    _expiryTimer?.cancel();
    _expiryTimer = null;
    scheduleMicrotask(() async {
      if (generation != _degradeGeneration) return;
      await _prefs.setDegradedUntil(null);
      if (generation != _degradeGeneration) {
        // Re-armed during the await; restore prefs from current memory.
        final armed = _degradedUntil;
        if (armed != null) await _prefs.setDegradedUntil(armed);
        return;
      }
      if (!_disposed) notifyListeners();
    });
  }

  void _scheduleExpiryTimer() {
    _expiryTimer?.cancel();
    _expiryTimer = null;
    final until = _degradedUntil;
    if (until == null) return;
    final remaining = until.difference(_clock());
    if (remaining <= Duration.zero) {
      _syncExpiryOnAccess();
      return;
    }
    _expiryTimer = Timer(remaining, () {
      _syncExpiryOnAccess();
    });
  }

  Future<void> _clearIfExpired({DateTime? now}) async {
    final until = _degradedUntil;
    if (until == null) return;
    final t = now ?? _clock();
    if (!t.isBefore(until)) {
      await _clearDegraded();
    }
  }

  Future<void> _clearDegraded() async {
    _degradeGeneration++;
    _expiryTimer?.cancel();
    _expiryTimer = null;
    if (_degradedUntil == null) {
      await _prefs.setDegradedUntil(null);
      return;
    }
    _degradedUntil = null;
    await _prefs.setDegradedUntil(null);
  }

  @override
  void dispose() {
    _disposed = true;
    _expiryTimer?.cancel();
    super.dispose();
  }
}
