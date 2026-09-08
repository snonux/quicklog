import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quicklog/services/log_service.dart';
import 'package:quicklog/services/preferences.dart';
import 'package:quicklog/services/s3_session_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late DateTime now;
  late PreferencesService prefs;
  late S3SessionController session;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    now = DateTime.utc(2026, 9, 8, 10, 0, 0);
    prefs = PreferencesService();
    session = S3SessionController(
      preferences: prefs,
      clock: () => now,
    );
    await session.load(now: now);
  });

  tearDown(() {
    session.dispose();
  });

  group('mode toggle', () {
    test('defaults to local-only', () {
      expect(session.preferredMode, StorageMode.local);
      expect(session.usesLocalFallback, isTrue);
      expect(session.shouldAttemptS3, isFalse);
      expect(session.isDegraded, isFalse);
    });

    test('switching to s3 enables S3 when not degraded', () async {
      await session.setPreferredMode(StorageMode.s3);
      expect(session.preferredMode, StorageMode.s3);
      expect(session.shouldAttemptS3, isTrue);
      expect(session.usesLocalFallback, isFalse);
      expect(await prefs.storageMode(), StorageMode.s3);
    });

    test('switching back to local clears degrade and stays local', () async {
      await session.setPreferredMode(StorageMode.s3);
      await session.markS3Failed(now: now);
      expect(session.isDegraded, isTrue);

      await session.setPreferredMode(StorageMode.local);
      expect(session.isDegraded, isFalse);
      expect(session.usesLocalFallback, isTrue);
      expect(session.degradedUntil, isNull);
      expect(await prefs.degradedUntil(), isNull);
    });
  });

  group('degrade', () {
    test('markS3Failed arms a 1h window and forces local fallback', () async {
      await session.setPreferredMode(StorageMode.s3);
      await session.markS3Failed(now: now);

      expect(session.isDegraded, isTrue);
      expect(session.usesLocalFallback, isTrue);
      expect(session.shouldAttemptS3, isFalse);
      expect(session.degradedUntil, now.add(kS3DegradeDuration));
      expect(await prefs.degradedUntil(), now.add(kS3DegradeDuration));
    });

    test('markS3Failed is a no-op when preferred mode is local', () async {
      var notified = 0;
      session.addListener(() => notified++);

      await session.markS3Failed(now: now);

      expect(session.degradedUntil, isNull);
      expect(await prefs.degradedUntil(), isNull);
      expect(session.isDegraded, isFalse);
      expect(notified, 0);
    });

    test('resolveStore returns local while degraded even if s3 factory given',
        () async {
      await session.setPreferredMode(StorageMode.s3);
      await session.markS3Failed(now: now);

      final local = _FakeStore('local');
      final s3 = _FakeStore('s3');
      final active = session.resolveStore(
        local: () => local,
        s3: () => s3,
      );
      expect(identical(active, local), isTrue);
    });

    test('resolveStore returns s3 when preferred and not degraded', () async {
      await session.setPreferredMode(StorageMode.s3);
      final local = _FakeStore('local');
      final s3 = _FakeStore('s3');
      final active = session.resolveStore(
        local: () => local,
        s3: () => s3,
      );
      expect(identical(active, s3), isTrue);
    });

    test('resolveStore uses local when s3 factory is null but shouldAttemptS3',
        () async {
      await session.setPreferredMode(StorageMode.s3);
      expect(session.shouldAttemptS3, isTrue);

      final local = _FakeStore('local');
      final active = session.resolveStore(local: () => local);
      expect(identical(active, local), isTrue);
    });
  });

  group('1h expiry', () {
    test('after the window elapses, S3 is attempted again mid-session',
        () async {
      await session.setPreferredMode(StorageMode.s3);
      await session.markS3Failed(now: now);

      now = now.add(kS3DegradeDuration);
      expect(session.isDegraded, isFalse);
      expect(session.shouldAttemptS3, isTrue);
      await pumpEventQueue();
    });

    test('mid-session expiry clears prefs and notifies listeners', () async {
      await session.setPreferredMode(StorageMode.s3);
      await session.markS3Failed(now: now);

      var notified = 0;
      session.addListener(() => notified++);

      now = now.add(kS3DegradeDuration);
      expect(session.isDegraded, isFalse);
      await pumpEventQueue();

      expect(session.degradedUntil, isNull);
      expect(await prefs.degradedUntil(), isNull);
      expect(notified, greaterThan(0));
    });

    test('expiry prefs clear does not wipe a newly armed window', () async {
      await session.setPreferredMode(StorageMode.s3);
      await session.markS3Failed(now: now);

      now = now.add(kS3DegradeDuration);
      // Schedules an async prefs clear for the expired window.
      expect(session.isDegraded, isFalse);

      // Re-arm before that deferred clear finishes writing null.
      final rearmAt = now;
      await session.markS3Failed(now: rearmAt);
      final armedUntil = rearmAt.add(kS3DegradeDuration);
      expect(session.degradedUntil, armedUntil);

      await pumpEventQueue();

      expect(session.degradedUntil, armedUntil);
      expect(await prefs.degradedUntil(), armedUntil);
      expect(session.isDegraded, isTrue);
    });

    test('expiry prefs clear does not wipe after concurrent retryS3 re-arm',
        () async {
      await session.setPreferredMode(StorageMode.s3);
      await session.markS3Failed(now: now);

      now = now.add(kS3DegradeDuration);
      expect(session.isDegraded, isFalse);

      final retryAt = now.add(const Duration(minutes: 1));
      now = retryAt;
      final result = await session.retryS3(
        probe: () async {
          throw Exception('still down');
        },
        now: retryAt,
      );
      expect(result, S3RetryResult.unavailable);
      final armedUntil = retryAt.add(kS3DegradeDuration);

      await pumpEventQueue();

      expect(session.degradedUntil, armedUntil);
      expect(await prefs.degradedUntil(), armedUntil);
      expect(session.isDegraded, isTrue);
    });

    test('just before expiry remains degraded', () async {
      await session.setPreferredMode(StorageMode.s3);
      await session.markS3Failed(now: now);

      now = now.add(kS3DegradeDuration).subtract(const Duration(seconds: 1));
      expect(session.isDegraded, isTrue);
    });
  });

  group('cold-start', () {
    test('load clears an expired persisted window so S3 can be retried',
        () async {
      await prefs.setStorageMode(StorageMode.s3);
      await prefs.setDegradedUntil(now.subtract(const Duration(minutes: 1)));

      final cold = S3SessionController(
        preferences: prefs,
        clock: () => now,
      );
      await cold.load(now: now);

      expect(cold.preferredMode, StorageMode.s3);
      expect(cold.degradedUntil, isNull);
      expect(cold.isDegraded, isFalse);
      expect(cold.shouldAttemptS3, isTrue);
      expect(await prefs.degradedUntil(), isNull);
      cold.dispose();
    });

    test('load keeps a still-active persisted window', () async {
      final until = now.add(const Duration(minutes: 30));
      await prefs.setStorageMode(StorageMode.s3);
      await prefs.setDegradedUntil(until);

      final cold = S3SessionController(
        preferences: prefs,
        clock: () => now,
      );
      await cold.load(now: now);

      expect(cold.degradedUntil, until);
      expect(cold.isDegraded, isTrue);
      expect(cold.usesLocalFallback, isTrue);
      cold.dispose();
    });

    test('second load does not resurrect a cleared degrade window', () async {
      await session.setPreferredMode(StorageMode.s3);
      await session.markS3Failed(now: now);
      expect(await prefs.degradedUntil(), isNotNull);

      await session.retryS3(probe: () async {});
      expect(session.degradedUntil, isNull);

      // Stale prefs would resurrect if load re-read them; idempotent load must not.
      await prefs.setDegradedUntil(now.add(kS3DegradeDuration));
      await session.load(now: now);

      expect(session.degradedUntil, isNull);
      expect(session.isDegraded, isFalse);
    });
  });

  group('manual retry', () {
    test('successful probe clears degrade and stays on S3', () async {
      await session.setPreferredMode(StorageMode.s3);
      await session.markS3Failed(now: now);
      var probed = false;

      final result = await session.retryS3(
        probe: () async {
          probed = true;
        },
        now: now,
      );

      expect(result, S3RetryResult.reachable);
      expect(probed, isTrue);
      expect(session.isDegraded, isFalse);
      expect(session.shouldAttemptS3, isTrue);
      expect(await prefs.degradedUntil(), isNull);
    });

    test('failed probe re-arms the 1h degrade window', () async {
      await session.setPreferredMode(StorageMode.s3);
      await session.markS3Failed(now: now);
      final retryAt = now.add(const Duration(minutes: 5));
      now = retryAt;

      final result = await session.retryS3(
        probe: () async {
          throw Exception('network down');
        },
        now: retryAt,
      );

      expect(result, S3RetryResult.unavailable);
      expect(session.isDegraded, isTrue);
      expect(session.degradedUntil, retryAt.add(kS3DegradeDuration));
    });

    test('retry is a no-op when preferred mode is local', () async {
      final result = await session.retryS3(probe: () async {});
      expect(result, S3RetryResult.ignored);
    });

    test('retry without probe clears degrade optimistically', () async {
      await session.setPreferredMode(StorageMode.s3);
      await session.markS3Failed(now: now);
      expect(session.isDegraded, isTrue);

      final result = await session.retryS3();
      expect(result, S3RetryResult.armedWithoutProbe);
      expect(session.isDegraded, isFalse);
      expect(session.degradedUntil, isNull);
      expect(await prefs.degradedUntil(), isNull);
      expect(session.shouldAttemptS3, isTrue);
    });
  });

  group('corrupt prefs', () {
    test('corrupt S3DegradedUntil parses to null', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'flutter.S3DegradedUntil': 'not-a-timestamp',
        'flutter.StorageMode': 's3',
      });
      final freshPrefs = PreferencesService();
      expect(await freshPrefs.degradedUntil(), isNull);

      final cold = S3SessionController(
        preferences: freshPrefs,
        clock: () => now,
      );
      await cold.load(now: now);
      expect(cold.degradedUntil, isNull);
      expect(cold.isDegraded, isFalse);
      cold.dispose();
    });
  });
}

class _FakeStore implements NoteStore {
  _FakeStore(this.label);
  final String label;

  @override
  Future<LogEntry> create(String text, {DateTime? now}) =>
      throw UnimplementedError(label);

  @override
  Future<void> delete(String id) => throw UnimplementedError(label);

  @override
  Future<String> firstLine(String id) => throw UnimplementedError(label);

  @override
  Future<List<LogEntry>> list() => throw UnimplementedError(label);

  @override
  Future<String> preview(String id, {int maxChars = 200}) =>
      throw UnimplementedError(label);

  @override
  Future<String> read(String id) => throw UnimplementedError(label);

  @override
  Future<void> update(String id, String text) =>
      throw UnimplementedError(label);
}
