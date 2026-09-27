import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:quicklog/services/active_note_store.dart';
import 'package:quicklog/services/preferences.dart';
import 'package:quicklog/services/s3_object_client.dart';
import 'package:quicklog/services/s3_session_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Pins the [ActiveNoteStore.createNote] outcome matrix per storage mode on
/// the paths that s3_active_store_test.dart and invalid_s3_endpoint_test.dart
/// do not cover: when S3 is skipped, and which error wins when the local
/// write fails as well as S3.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final now = DateTime(2026, 9, 27, 11, 30);
  const id = 'ql-260927-113000.md';

  late Directory tmp;
  late S3SessionController session;
  late MemoryS3ObjectClient fakeS3;
  late int factoryCalls;
  // What the S3 client factory throws instead of returning [fakeS3].
  Object? factoryError;

  /// A store over prefs seeded with [mode]; [credentials] false leaves the
  /// S3 keys empty, [blockLocal] points the log directory below a regular
  /// file so every local write fails.
  Future<ActiveNoteStore> storeFor(
    StorageMode mode, {
    bool credentials = true,
    bool blockLocal = false,
  }) async {
    var dir = tmp.path;
    if (blockLocal) {
      await File(p.join(tmp.path, 'blocked')).writeAsString('not a dir');
      dir = p.join(tmp.path, 'blocked', 'sub');
    }
    SharedPreferences.setMockInitialValues(<String, Object>{
      'flutter.Directory': dir,
      'flutter.StorageMode': mode.name,
      if (credentials) 'flutter.S3AccessKeyId': 'AKIA_TEST',
      if (credentials) 'flutter.S3SecretAccessKey': 'secret_test',
    });
    final prefs = PreferencesService();
    session = S3SessionController(preferences: prefs);
    await session.load();
    return ActiveNoteStore(
      preferences: prefs,
      session: session,
      s3ClientFactory: (_) {
        factoryCalls++;
        final error = factoryError;
        if (error != null) throw error;
        return fakeS3;
      },
    );
  }

  String? localText() {
    final file = File(p.join(tmp.path, id));
    return file.existsSync() ? file.readAsStringSync() : null;
  }

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('ql-create-outcomes-');
    fakeS3 = MemoryS3ObjectClient();
    factoryCalls = 0;
    factoryError = null;
  });

  tearDown(() async {
    session.dispose();
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  group('local mode', () {
    test('never builds an S3 client, even with broken settings', () async {
      final active = await storeFor(StorageMode.local);
      factoryError = const S3ConfigException('bad endpoint');

      final result = await active.createNote('local', now: now);

      expect(result.outcome, NoteCreateOutcome.saved);
      expect(result.entry.id, id);
      expect(localText(), 'local');
      expect(factoryCalls, 0);
      expect(session.isDegraded, isFalse);
    });

    test('without credentials is not a fallback and arms nothing', () async {
      final active = await storeFor(StorageMode.local, credentials: false);

      final result = await active.createNote('local', now: now);

      expect(result.outcome, NoteCreateOutcome.saved);
      expect(session.isDegraded, isFalse);
    });

    test('a local failure propagates', () async {
      final active = await storeFor(StorageMode.local, blockLocal: true);

      await expectLater(
        active.createNote('lost', now: now),
        throwsA(isA<FileSystemException>()),
      );
    });
  });

  for (final mode in [StorageMode.s3, StorageMode.both]) {
    group('${mode.name} mode', () {
      test('inside the degrade window: local only, S3 untouched', () async {
        final active = await storeFor(mode);
        await session.markS3Failed();

        final result = await active.createNote('degraded', now: now);

        expect(result.outcome, NoteCreateOutcome.savedLocalOnly);
        expect(result.entry.id, id);
        expect(localText(), 'degraded');
        expect(factoryCalls, 0);
        expect(fakeS3.calls, 0);
      });

      test('without credentials: local only and arms the window', () async {
        final active = await storeFor(mode, credentials: false);

        final result = await active.createNote('no creds', now: now);

        expect(result.outcome, NoteCreateOutcome.savedLocalOnly);
        expect(localText(), 'no creds');
        expect(factoryCalls, 0);
        expect(session.isDegraded, isTrue);
      });

      test('invalid settings: kept locally once, no window armed', () async {
        final active = await storeFor(mode);
        factoryError = const S3ConfigException('bad endpoint');

        final result = await active.createNote('settings', now: now);

        expect(result.outcome, NoteCreateOutcome.savedLocalS3SettingsInvalid);
        expect(result.entry.id, id);
        expect(localText(), 'settings');
        expect(
          tmp.listSync().where((e) => e.path.endsWith('.md')),
          hasLength(1),
        );
        expect(session.isDegraded, isFalse);
      });

      test('invalid settings with a failing local write: the local error '
          'propagates', () async {
        final active = await storeFor(mode, blockLocal: true);
        factoryError = const S3ConfigException('bad endpoint');

        await expectLater(
          active.createNote('lost', now: now),
          throwsA(isA<FileSystemException>()),
        );
        expect(session.isDegraded, isFalse);
      });

      test('S3 outage with a failing local write: the local error '
          'propagates', () async {
        final active = await storeFor(mode, blockLocal: true);
        fakeS3.alwaysFail = Exception('network down');

        await expectLater(
          active.createNote('lost', now: now),
          throwsA(isA<FileSystemException>()),
        );
        expect(fakeS3.objects, isEmpty);
        expect(session.isDegraded, isTrue);
      });

      if (mode == StorageMode.both) {
        test('ArgumentError with a failing local write: the ArgumentError '
            'propagates', () async {
          final active = await storeFor(mode, blockLocal: true);
          fakeS3.alwaysFail = ArgumentError('bad key');

          await expectLater(
            active.createNote('lost', now: now),
            throwsA(isA<ArgumentError>()),
          );
          expect(session.isDegraded, isFalse);
        });

        test('S3 outage with a failing local write: the local error keeps '
            'its original stack trace', () async {
          final active = await storeFor(mode, blockLocal: true);
          fakeS3.alwaysFail = Exception('network down');

          StackTrace? stack;
          try {
            await active.createNote('lost', now: now);
          } on FileSystemException catch (_, st) {
            stack = st;
          }
          // The trace points at the failed local write, not at the rethrow
          // inside the S3 fallback.
          expect(stack.toString(), contains('log_service.dart'));
        });
      } else {
        test(
          'ArgumentError propagates before any local write is attempted',
          () async {
            final active = await storeFor(mode);
            fakeS3.alwaysFail = ArgumentError('bad key');

            await expectLater(
              active.createNote('lost', now: now),
              throwsA(isA<ArgumentError>()),
            );
            expect(localText(), isNull);
            expect(tmp.listSync(), isEmpty);
            expect(session.isDegraded, isFalse);
          },
        );
      }

      test('without an explicit time, the S3 key and the local fallback '
          'share one id', () async {
        final active = await storeFor(mode);
        // The put lands, then the response is lost: the note falls back to
        // local, and both copies must carry the same stamp.
        fakeS3.putSucceedsButThrows = Exception('response lost');

        final result = await active.createNote('same id');

        expect(result.outcome, NoteCreateOutcome.savedLocalOnly);
        expect(fakeS3.objects.keys, [result.entry.id]);
        expect(
          File(p.join(tmp.path, result.entry.id)).readAsStringSync(),
          'same id',
        );
        expect(
          tmp.listSync().where((e) => e.path.endsWith('.md')),
          hasLength(1),
        );
      });
    });
  }

  test(
    's3 mode: the S3 entry is returned and no local copy is written',
    () async {
      final active = await storeFor(StorageMode.s3);

      final result = await active.createNote('bucket', now: now);

      expect(result.outcome, NoteCreateOutcome.saved);
      expect(result.entry.id, id);
      expect(fakeS3.objects.keys, [id]);
      expect(localText(), isNull);
    },
  );

  test('both mode: a failing local write with S3 up is savedS3Only and '
      'arms no window', () async {
    final active = await storeFor(StorageMode.both, blockLocal: true);

    final result = await active.createNote('bucket only', now: now);

    expect(result.outcome, NoteCreateOutcome.savedS3Only);
    expect(result.entry.id, id);
    expect(fakeS3.objects.keys, [id]);
    expect(session.isDegraded, isFalse);
  });
}
