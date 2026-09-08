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
  });

  group('1h expiry', () {
    test('after the window elapses, S3 is attempted again mid-session',
        () async {
      await session.setPreferredMode(StorageMode.s3);
      await session.markS3Failed(now: now);

      now = now.add(kS3DegradeDuration);
      expect(session.isDegraded, isFalse);
      expect(session.shouldAttemptS3, isTrue);
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
    });
  });

  group('manual retry', () {
    test('successful probe clears degrade and stays on S3', () async {
      await session.setPreferredMode(StorageMode.s3);
      await session.markS3Failed(now: now);
      var probed = false;

      final ok = await session.retryS3(
        probe: () async {
          probed = true;
        },
        now: now,
      );

      expect(ok, isTrue);
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

      final ok = await session.retryS3(
        probe: () async {
          throw Exception('network down');
        },
        now: retryAt,
      );

      expect(ok, isFalse);
      expect(session.isDegraded, isTrue);
      expect(session.degradedUntil, retryAt.add(kS3DegradeDuration));
    });

    test('retry is a no-op when preferred mode is local', () async {
      final ok = await session.retryS3(probe: () async {});
      expect(ok, isFalse);
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
