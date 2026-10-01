import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/widgets.dart';
import 'package:workmanager/workmanager.dart';

import 'preferences.dart';

const s3RetryTaskName = 'org.buetow.quicklog.s3-retry';
const s3RetryTaskTag = 'quicklog-s3-retry';

abstract interface class S3RetryJobQueue {
  Future<void> enqueue({
    required String identity,
    required DateTime due,
    required Duration delay,
  });
  Future<void> cancel();
}

class AndroidS3RetryJobQueue implements S3RetryJobQueue {
  @override
  Future<void> enqueue({
    required String identity,
    required DateTime due,
    required Duration delay,
  }) => Workmanager().registerOneOffTask(
    '$s3RetryTaskName.$identity.${due.millisecondsSinceEpoch}',
    s3RetryTaskName,
    tag: s3RetryTaskTag,
    inputData: {'identity': identity},
    initialDelay: delay,
    existingWorkPolicy: ExistingWorkPolicy.keep,
    constraints: Constraints(networkType: NetworkType.connected),
  );

  @override
  Future<void> cancel() => Workmanager().cancelByTag(s3RetryTaskTag);
}

/// Android persists one future occurrence. Every callback schedules the next
/// occurrence before network work, so failure or worker termination cannot
/// break the daily chain. Linux uses an in-process timer instead.
class S3RetryScheduler with WidgetsBindingObserver {
  S3RetryScheduler({
    required Future<void> Function() retry,
    PreferencesService? preferences,
    S3RetryJobQueue? jobs,
    DateTime Function()? clock,
    bool? android,
    bool backgroundWorker = false,
    Future<void> Function()? onResumed,
  }) : _retry = retry,
       _prefs = preferences ?? PreferencesService(),
       _jobs = jobs ?? AndroidS3RetryJobQueue(),
       _clock = clock ?? DateTime.now,
       _android = android ?? Platform.isAndroid,
       _backgroundWorker = backgroundWorker,
       _onResumed = onResumed;

  /// Set by the app after initialization; tests and background workers do not
  /// replace the running UI's scheduler.
  static S3RetryScheduler? current;

  final Future<void> Function() _retry;
  final PreferencesService _prefs;
  final S3RetryJobQueue _jobs;
  final DateTime Function() _clock;
  final bool _android;
  final bool _backgroundWorker;
  final Future<void> Function()? _onResumed;
  bool _backgroundEnabled = false;
  bool get _usesBackground => _android && _backgroundEnabled;
  Timer? _timer;
  bool _disposed = false;
  bool _foreground = true;
  bool get isForeground => _foreground;
  bool _running = false;
  String? _identity;
  Future<void> _changes = Future<void>.value();

  Future<String> identity() async {
    final config = await _prefs.s3Config();
    final schedule = await _prefs.s3RetrySchedule();
    return sha256
        .convert(
          utf8.encode(
            jsonEncode([
              (await _prefs.storageMode()).wireName,
              schedule.times,
              await _prefs.s3RetryInBackground(),
              config.endpoint,
              config.region,
              config.bucket,
              config.accessKeyId,
              config.secretAccessKey,
              await _prefs.localStoreKey(),
            ]),
          ),
        )
        .toString();
  }

  Future<void> start() async {
    WidgetsBinding.instance.addObserver(this);
    await refresh();
  }

  /// Save/import calls [refresh] with replace=true. Startup uses KEEP, which
  /// neither cancels a running callback nor postpones an already queued retry.
  Future<void> refresh({bool replace = false}) {
    final result = _changes.then((_) => _refresh(replace: replace));
    _changes = result.then((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<void> _refresh({required bool replace}) async {
    if (_disposed) return;
    await _prefs.reload();
    final nextIdentity = await identity();
    final schedule = await _prefs.s3RetrySchedule();
    _backgroundEnabled = await _prefs.s3RetryInBackground();
    final enabled =
        await _prefs.storageMode() == StorageMode.s3 && schedule.enabled;
    if (_disposed) return;
    final changed = _identity != null && _identity != nextIdentity;
    _identity = nextIdentity;
    _timer?.cancel();
    _timer = null;
    if (_android && replace && (changed || !enabled || !_usesBackground)) {
      await _jobs.cancel();
    }
    if (!enabled || (!_usesBackground && (!_foreground || _backgroundWorker))) {
      return;
    }
    final now = _clock();
    final due = schedule.nextAfter(now)!;
    if (_usesBackground) {
      await _jobs.enqueue(
        identity: nextIdentity,
        due: due,
        delay: due.difference(now),
      );
    } else {
      _timer = Timer(due.difference(now), () {
        unawaited(runScheduled(nextIdentity));
      });
    }
  }

  /// Revalidates stale jobs after settings changed. A failed S3 pass waits for
  /// the next selected time; WorkManager backoff never adds surprise retries.
  Future<void> runScheduled(String scheduledIdentity) async {
    if (_disposed || _running || (!_usesBackground && !_foreground)) return;
    _running = true;
    try {
      await _prefs.reload();
      final valid =
          await _prefs.storageMode() == StorageMode.s3 &&
          (!_backgroundWorker || await _prefs.s3RetryInBackground()) &&
          await identity() == scheduledIdentity;
      // Arm the next occurrence first, including after an empty local run.
      await refresh();
      if (valid && !_disposed) {
        // Settings can change while the next native occurrence is enqueued.
        await _prefs.reload();
        if (await _prefs.storageMode() == StorageMode.s3 &&
            (!_backgroundWorker || await _prefs.s3RetryInBackground()) &&
            await identity() == scheduledIdentity &&
            (_usesBackground || _foreground)) {
          await _retry();
        }
      }
    } catch (_) {
      // Local notes and any unconfirmed receipts remain for the next slot.
    } finally {
      _running = false;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (_foreground) {
      final resume = _onResumed;
      if (resume != null) unawaited(resume());
    }
    if (_usesBackground) return;
    if (_foreground) {
      unawaited(refresh());
    } else {
      _timer?.cancel();
      _timer = null;
    }
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    if (identical(current, this)) current = null;
  }
}
