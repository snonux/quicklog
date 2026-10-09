import 'package:flutter_test/flutter_test.dart';
import 'package:minio/minio.dart';
import 'package:minio/models.dart' as minio_models;
import 'package:quicklog/services/preferences.dart';
import 'package:quicklog/services/s3_note_store.dart';
import 'package:quicklog/services/s3_object_client.dart';
import 'package:quicklog/services/s3_session_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/memory_s3_object_client.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MemoryS3ObjectClient client;
  late S3NoteStore store;

  setUp(() {
    client = MemoryS3ObjectClient();
    store = S3NoteStore(client);
  });

  group('S3NoteStore CRUD', () {
    test('create/list/read/update/delete ql-*.md keys', () async {
      final now = DateTime(2026, 9, 8, 10, 22, 30);
      final entry = await store.create('hello\nworld', now: now);

      expect(entry.id, 'ql-260908-102230.md');
      expect(client.objects.keys, ['ql-260908-102230.md']);
      expect(await store.read(entry.id), 'hello\nworld');

      final listed = await store.list();
      expect(listed.map((e) => e.id), ['ql-260908-102230.md']);

      await store.update(entry.id, 'edited');
      expect(await store.read(entry.id), 'edited');
      // Edit keeps the same key (creation stamp in the name).
      expect(client.objects.keys.single, entry.id);

      await store.delete(entry.id);
      expect(client.objects, isEmpty);
      expect(await store.list(), isEmpty);
    });

    test('list ignores non ql-*.md keys and sorts newest first', () async {
      await client.putText('noise.txt', 'x');
      await store.create('older', now: DateTime(2026, 9, 8, 10, 0, 0));
      await store.create('newer', now: DateTime(2026, 9, 8, 11, 0, 0));

      final listed = await store.list();
      expect(listed.map((e) => e.id).toList(), [
        'ql-260908-110000.md',
        'ql-260908-100000.md',
      ]);
    });

    // v0.4.0 uploaded attached images as `ql-img-*` objects beside the
    // notes. Image support was removed, the objects were not: they must be
    // skipped by the listing and never read, overwritten or deleted.
    test('image objects left by v0.4.0 are skipped and kept', () async {
      const imageKey = 'ql-img-260908-100000-123.jpg';
      const imageBytes = [0xFF, 0xD8, 0xFF, 0xE0];
      const linked = 'see\n![]($imageKey)';
      await client.putObject(imageKey, imageBytes, contentType: 'image/jpeg');
      final note = await store.create(
        linked,
        now: DateTime(2026, 9, 8, 10, 0, 0),
      );

      expect((await store.list()).map((e) => e.id), [note.id]);
      expect(await store.read(note.id), linked);
      // Awaited: the refusals must be over before the bucket is checked.
      await expectLater(() => store.read(imageKey), throwsArgumentError);
      await expectLater(() => store.update(imageKey, 'x'), throwsArgumentError);
      await expectLater(() => store.delete(imageKey), throwsArgumentError);

      await store.delete(note.id);
      expect(await store.list(), isEmpty);
      expect(client.objects, {imageKey: imageBytes});
    });

    test('malformed image leftovers are skipped and kept too', () async {
      // A name dressed up as a note, a type v0.4.0 never wrote, and a
      // zero-byte object.
      const odd = [
        'ql-img-260908-100000-123.md',
        'ql-img-260908-100000-124.bmp',
        'ql-img-260908-100000-125.jpg',
      ];
      for (final key in odd) {
        await client.putObject(key, const []);
      }

      expect(await store.list(), isEmpty);
      for (final key in odd) {
        await expectLater(() => store.read(key), throwsArgumentError);
        await expectLater(() => store.delete(key), throwsArgumentError);
      }
      expect(client.objects.keys, odd);
    });

    test('rejects unsafe ids', () async {
      expect(
        () => store.read('../escape.md'),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('firstLine swallows read errors; preview propagates', () async {
      expect(await store.firstLine('ql-260908-000000.md'), '');
      expect(
        () => store.preview('ql-260908-000000.md'),
        throwsA(isA<S3MissingObjectError>()),
      );
    });
  });

  group('failure → session degrade', () {
    late PreferencesService prefs;
    late S3SessionController session;
    late DateTime now;

    setUp(() async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      now = DateTime.utc(2026, 9, 8, 12, 0, 0);
      prefs = PreferencesService();
      session = S3SessionController(
        preferences: prefs,
        clock: () => now,
      );
      await session.load(now: now);
      await session.setPreferredMode(StorageMode.s3);
      client = MemoryS3ObjectClient();
      store = S3NoteStore(
        client,
        onFailure: () => session.markS3Failed(now: now),
      );
    });

    tearDown(() => session.dispose());

    test('I/O failure calls markS3Failed', () async {
      client.alwaysFail = Exception('network down');

      await expectLater(store.list(), throwsA(isA<Exception>()));
      expect(session.isDegraded, isTrue);
      expect(session.usesLocalFallback, isTrue);
    });

    test('ArgumentError (bad id) does not markS3Failed', () async {
      await expectLater(
        store.read('../escape.md'),
        throwsA(isA<ArgumentError>()),
      );
      expect(session.isDegraded, isFalse);
    });

    test('missing object on read does not markS3Failed', () async {
      await expectLater(
        store.read('ql-260908-000000.md'),
        throwsA(isA<S3MissingObjectError>()),
      );
      expect(session.isDegraded, isFalse);
    });

    test('Minio NoSuchKey on read does not markS3Failed', () async {
      client.failNext = MinioS3Error(
        'missing',
        minio_models.Error('NoSuchKey', 'k', 'missing', null),
      );
      await expectLater(
        store.read('ql-260908-102230.md'),
        throwsA(isA<MinioS3Error>()),
      );
      expect(session.isDegraded, isFalse);
    });

    test('Minio NoSuchBucket on read marks S3 failed', () async {
      client.failNext = MinioS3Error(
        'bucket',
        minio_models.Error('NoSuchBucket', null, 'missing', null),
      );
      await expectLater(
        store.read('ql-260908-102230.md'),
        throwsA(isA<MinioS3Error>()),
      );
      expect(session.isDegraded, isTrue);
    });

    test('NoSuchBucket / NotFound / 404 on list marks S3 failed', () async {
      for (final err in [
        StateError('NoSuchBucket: quicklog'),
        Exception('NotFound'),
        Exception('HTTP 404'),
      ]) {
        await session.retryS3(probe: () async {}, now: now);
        expect(session.isDegraded, isFalse);

        client.failNext = err;
        await expectLater(store.list(), throwsA(anything));
        expect(session.isDegraded, isTrue, reason: '$err');
      }
    });

    test('NoSuchBucket on create/probe marks S3 failed', () async {
      client.failNext = StateError('NoSuchBucket: quicklog');
      await expectLater(store.create('x'), throwsA(isA<StateError>()));
      expect(session.isDegraded, isTrue);

      await session.retryS3(probe: () async {}, now: now);
      expect(session.isDegraded, isFalse);

      client.failNext = StateError('NoSuchBucket: quicklog');
      await expectLater(store.probe(), throwsA(isA<StateError>()));
      expect(session.isDegraded, isTrue);
    });

    test('a missing object on create still marks S3 failed', () async {
      for (final err in [
        const S3MissingObjectError('unexpected'),
        MinioS3Error(
          'missing',
          minio_models.Error('NoSuchKey', 'unexpected', 'missing', null),
        ),
      ]) {
        await session.retryS3(probe: () async {}, now: now);
        expect(session.isDegraded, isFalse);

        client.failNext = err;
        await expectLater(store.create('x'), throwsA(anything));
        expect(session.isDegraded, isTrue, reason: '$err');
      }
    });

    test('firstLine never marks S3 failed (missing or transport)', () async {
      expect(await store.firstLine('ql-260908-000000.md'), '');
      expect(session.isDegraded, isFalse);

      client.alwaysFail = Exception('network down');
      expect(await store.firstLine('ql-260908-102230.md'), '');
      expect(session.isDegraded, isFalse);
    });

    test('probe failure degrades; successful probe does not', () async {
      await store.probe();
      expect(session.isDegraded, isFalse);

      client.failNext = Exception('boom');
      await expectLater(store.probe(), throwsA(isA<Exception>()));
      expect(session.isDegraded, isTrue);
    });
  });

  group('isMissingObjectError', () {
    test('matches typed missing-object errors only', () {
      expect(isMissingObjectError(const S3MissingObjectError('k')), isTrue);
      expect(
        isMissingObjectError(
          MinioS3Error(
            'missing',
            minio_models.Error('NoSuchKey', 'k', 'missing', null),
          ),
        ),
        isTrue,
      );
      expect(
        isMissingObjectError(
          MinioS3Error(
            'bucket',
            minio_models.Error('NoSuchBucket', null, 'missing', null),
          ),
        ),
        isFalse,
      );
      expect(isMissingObjectError(MinioS3Error('bare')), isFalse);
      expect(isMissingObjectError(StateError('NoSuchKey: k')), isFalse);
      expect(isMissingObjectError(StateError('NoSuchBucket: b')), isFalse);
      expect(isMissingObjectError(Exception('NoSuchKey: k')), isFalse);
      expect(isMissingObjectError(Exception('NotFound')), isFalse);
      expect(isMissingObjectError(Exception('HTTP 404')), isFalse);
    });
  });
}
