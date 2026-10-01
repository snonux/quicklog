import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quicklog/services/preferences.dart';
import 'package:quicklog/services/s3_config.dart';
import 'package:quicklog/services/s3_retry_schedule.dart';
import 'package:quicklog/services/s3_retry_scheduler.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Jobs implements S3RetryJobQueue {
  final queued = <({String identity, DateTime due, Duration delay})>[];
  int cancelled = 0;
  Future<void> Function()? onEnqueue;
  @override
  Future<void> cancel() async => cancelled++;
  @override
  Future<void> enqueue({
    required String identity,
    required DateTime due,
    required Duration delay,
  }) async {
    queued.add((identity: identity, due: due, delay: delay));
    await onEnqueue?.call();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late PreferencesService prefs;
  late _Jobs jobs;
  late DateTime now;
  late S3RetryScheduler scheduler;
  int calls = 0;
  Future<void> Function()? retry;

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'flutter.Directory': '/test-notes',
    });
    prefs = PreferencesService();
    jobs = _Jobs();
    now = DateTime.utc(2026, 10, 1, 8);
    calls = 0;
    retry = null;
    await prefs.setStorageMode(StorageMode.s3);
    await prefs.setS3RetryInBackground(true);
    await prefs.setS3RetrySchedule(S3RetrySchedule.parse(['09:00', '20:00']));
    scheduler = S3RetryScheduler(
      preferences: prefs,
      jobs: jobs,
      android: true,
      clock: () => now,
      retry: () async {
        calls++;
        await retry?.call();
      },
    );
  });
  tearDown(() => scheduler.dispose());

  test('startup keeps existing queue and registers next local time', () async {
    await scheduler.refresh();
    await scheduler.refresh();
    expect(jobs.cancelled, 0);
    expect(jobs.queued.first.due, DateTime.utc(2026, 10, 1, 9));
    expect(jobs.queued.first.delay, const Duration(hours: 1));
    expect(jobs.queued.first.identity, jobs.queued.last.identity);
  });

  test('next job is armed before retry, even when retry fails', () async {
    await scheduler.refresh();
    final identity = jobs.queued.last.identity;
    now = DateTime.utc(2026, 10, 1, 9);
    retry = () async {
      expect(jobs.queued.last.due, DateTime.utc(2026, 10, 1, 20));
      throw StateError('offline');
    };
    await scheduler.runScheduled(identity);
    expect(calls, 1);
  });

  test('changed schedule cancels its tag and rejects stale callback', () async {
    await scheduler.refresh();
    final previous = jobs.queued.last.identity;
    await prefs.setS3RetrySchedule(S3RetrySchedule.parse(['12:00']));
    await scheduler.refresh(replace: true);
    expect(jobs.cancelled, 1);
    expect(jobs.queued.last.due, DateTime.utc(2026, 10, 1, 12));
    await scheduler.runScheduled(previous);
    expect(calls, 0);
  });

  test('local and dual modes never retry, empty schedule disables', () async {
    await scheduler.refresh();
    final identity = jobs.queued.last.identity;
    for (final mode in [StorageMode.local, StorageMode.both]) {
      await prefs.setStorageMode(mode);
      await scheduler.refresh(replace: true);
      await scheduler.runScheduled(identity);
    }
    expect(calls, 0);
    await prefs.setStorageMode(StorageMode.s3);
    await prefs.setS3RetrySchedule(S3RetrySchedule([]));
    await scheduler.refresh(replace: true);
    await scheduler.runScheduled(identity);
    expect(calls, 0);
  });

  test(
    'bucket and folder edits reject old jobs and arm the new identity',
    () async {
      await scheduler.refresh();
      final previous = jobs.queued.last.identity;
      await prefs.setS3Config(S3Config.fromRaw(bucket: 'different-bucket'));
      await scheduler.runScheduled(previous);
      expect(calls, 0);
      expect(jobs.queued.last.identity, isNot(previous));
      final bucketIdentity = jobs.queued.last.identity;
      await prefs.setDirectory('/different-notes');
      await scheduler.runScheduled(bucketIdentity);
      expect(calls, 0);
      expect(jobs.queued.last.identity, isNot(bucketIdentity));
    },
  );

  test('disabling removes old tagged jobs without adding new jobs', () async {
    await scheduler.refresh();
    final count = jobs.queued.length;
    await prefs.setS3RetrySchedule(S3RetrySchedule([]));
    await scheduler.refresh(replace: true);
    expect(jobs.cancelled, 1);
    expect(jobs.queued.length, count);
  });

  test(
    'Android default foreground mode never enqueues and pauses with app',
    () async {
      await prefs.setS3RetryInBackground(false);
      await scheduler.refresh();
      expect(jobs.queued, isEmpty);
      final identity = await scheduler.identity();
      scheduler.didChangeAppLifecycleState(AppLifecycleState.paused);
      await scheduler.runScheduled(identity);
      expect(calls, 0);
    },
  );

  test(
    'switching off background retries cancels old jobs and skips old callback',
    () async {
      await scheduler.refresh();
      final old = jobs.queued.last.identity;
      final count = jobs.queued.length;
      await prefs.setS3RetryInBackground(false);
      await scheduler.refresh(replace: true);
      expect(jobs.cancelled, 1);
      expect(jobs.queued.length, count);
      await scheduler.runScheduled(old);
      expect(calls, 0);
    },
  );

  test(
    'mode or background flag changed while enqueue awaits skips upload',
    () async {
      await scheduler.refresh();
      final identity = jobs.queued.last.identity;
      jobs.onEnqueue = () => prefs.setStorageMode(StorageMode.local);
      await scheduler.runScheduled(identity);
      expect(calls, 0);
      await prefs.setStorageMode(StorageMode.s3);
      jobs.onEnqueue = null;
      await scheduler.refresh();
      final newIdentity = jobs.queued.last.identity;
      jobs.onEnqueue = () => prefs.setS3RetryInBackground(false);
      await scheduler.runScheduled(newIdentity);
      expect(calls, 0);
    },
  );

  test(
    'headless worker rejects foreground-only preference without timer',
    () async {
      scheduler.dispose();
      scheduler = S3RetryScheduler(
        preferences: prefs,
        jobs: jobs,
        android: true,
        backgroundWorker: true,
        clock: () => now,
        retry: () async {
          calls++;
        },
      );
      await prefs.setS3RetryInBackground(false);
      await scheduler.refresh();
      expect(jobs.queued, isEmpty);
      await scheduler.runScheduled(await scheduler.identity());
      expect(calls, 0);
    },
  );

  test('overlapping callbacks share one retry', () async {
    await scheduler.refresh();
    final gate = Completer<void>();
    retry = () => gate.future;
    final identity = jobs.queued.last.identity;
    final first = scheduler.runScheduled(identity);
    await Future<void>.delayed(Duration.zero);
    await scheduler.runScheduled(identity);
    expect(calls, 1);
    gate.complete();
    await first;
  });

  test(
    'Linux lifecycle stops foreground callbacks and dispose cancels timer',
    () async {
      scheduler.dispose();
      scheduler = S3RetryScheduler(
        preferences: prefs,
        jobs: jobs,
        android: false,
        clock: () => now,
        retry: () async {
          calls++;
        },
      );
      await scheduler.refresh();
      final identity = await scheduler.identity();
      scheduler.didChangeAppLifecycleState(AppLifecycleState.paused);
      await scheduler.runScheduled(identity);
      expect(calls, 0);
      scheduler.dispose();
      await scheduler.runScheduled(identity);
      expect(calls, 0);
    },
  );
}
