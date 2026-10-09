import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:quicklog/services/s3_drain.dart';
import 'package:quicklog/services/s3_object_client.dart';

import 'support/memory_s3_object_client.dart';

void main() {
  late Directory dest;
  late MemoryS3ObjectClient client;

  setUp(() async {
    dest = await Directory.systemTemp.createTemp('ql-drain-');
    client = MemoryS3ObjectClient();
  });

  tearDown(() async {
    if (await dest.exists()) await dest.delete(recursive: true);
  });

  test('fetch then delete remote; leaves local file', () async {
    await client.putText('ql-260908-100000.md', 'hello drain');
    final summary = await drainQuicklogObjects(client: client, destDir: dest);
    expect(summary.fetched, 1);
    expect(summary.deleted, 1);
    expect(summary.failed, 0);
    expect(client.objects.containsKey('ql-260908-100000.md'), isFalse);
    final file = File(p.join(dest.path, 'ql-260908-100000.md'));
    expect(await file.readAsString(), 'hello drain');
  });

  test('does not delete remote when local write fails', () async {
    const id = 'ql-260908-100001.md';
    await client.putText(id, 'keep remote');
    // Occupy the target path with a directory so the atomic rename fails.
    await Directory(p.join(dest.path, id)).create();

    final summary = await drainQuicklogObjects(client: client, destDir: dest);
    expect(summary.failed, 1);
    expect(summary.deleted, 0);
    expect(client.objects.containsKey(id), isTrue);
  });

  test('skips existing local file unless --force', () async {
    await client.putText('ql-260908-100002.md', 'remote');
    final local = File(p.join(dest.path, 'ql-260908-100002.md'));
    await local.writeAsString('local already');

    final skipped = await drainQuicklogObjects(client: client, destDir: dest);
    expect(skipped.skipped, 1);
    expect(skipped.fetched, 0);
    expect(client.objects.containsKey('ql-260908-100002.md'), isTrue);
    expect(await local.readAsString(), 'local already');

    final forced = await drainQuicklogObjects(
      client: client,
      destDir: dest,
      force: true,
    );
    expect(forced.fetched, 1);
    expect(forced.deleted, 1);
    expect(await local.readAsString(), 'remote');
  });

  test('dry-run does not write or delete', () async {
    await client.putText('ql-260908-100003.md', 'dry');
    final summary = await drainQuicklogObjects(
      client: client,
      destDir: dest,
      dryRun: true,
    );
    expect(summary.fetched, 1);
    expect(summary.deleted, 1);
    expect(client.objects.containsKey('ql-260908-100003.md'), isTrue);
    expect(
      await File(p.join(dest.path, 'ql-260908-100003.md')).exists(),
      isFalse,
    );
  });

  test('dry-run does not create missing dest directory', () async {
    final missing = Directory(p.join(dest.path, 'missing-subdir'));
    await client.putText('ql-260908-100004.md', 'dry');
    await drainQuicklogObjects(client: client, destDir: missing, dryRun: true);
    expect(await missing.exists(), isFalse);
  });

  test('reports delete failure after successful local write', () async {
    final flaky = _DeleteFailsClient();
    await flaky.putText('ql-260908-100005.md', 'local ok');
    final messages = <String>[];
    final summary = await drainQuicklogObjects(
      client: flaky,
      destDir: dest,
      onError: messages.add,
    );
    expect(summary.fetched, 1);
    expect(summary.deleted, 0);
    expect(summary.failed, 1);
    expect(messages.first, contains('delete failed'));
    expect(flaky.objects.containsKey('ql-260908-100005.md'), isTrue);
    expect(
      await File(p.join(dest.path, 'ql-260908-100005.md')).readAsString(),
      'local ok',
    );
  });

  test('limit caps how many objects are drained', () async {
    await client.putText('ql-260908-100010.md', 'a');
    await client.putText('ql-260908-100011.md', 'b');
    final summary = await drainQuicklogObjects(
      client: client,
      destDir: dest,
      limit: 1,
    );
    expect(summary.fetched, 1);
    expect(client.objects.length, 1);
  });

  test('ignores non ql-*.md keys', () async {
    await client.putText('readme.txt', 'nope');
    final summary = await drainQuicklogObjects(client: client, destDir: dest);
    expect(summary.fetched, 0);
    expect(client.objects.containsKey('readme.txt'), isTrue);
  });

  // Image objects written by v0.4.0 (`ql-img-*`) are not notes: the drain
  // must neither download them nor delete them from the bucket.
  test('leaves image objects from v0.4.0 in the bucket', () async {
    const imageKey = 'ql-img-260908-100000-123.jpg';
    await client.putObject(imageKey, [
      0xFF,
      0xD8,
      0xFF,
    ], contentType: 'image/jpeg');
    await client.putText('ql-260908-100000.md', '![]($imageKey)');

    final summary = await drainQuicklogObjects(client: client, destDir: dest);
    expect(summary.fetched, 1);
    expect(summary.deleted, 1);
    expect(summary.failed, 0);
    expect(client.objects.keys, [imageKey]);
    expect(client.objects[imageKey], [0xFF, 0xD8, 0xFF]);
    expect(await File(p.join(dest.path, imageKey)).exists(), isFalse);
    expect(await listQuicklogKeys(client: client), isEmpty);
    // Even asked for by name (`--delete`), an image is refused, not removed.
    final refused = await deleteQuicklogObjects(
      client: client,
      keys: [imageKey],
    );
    expect(refused.deleted, 0);
    expect(refused.failed, 1);
    expect(client.objects.keys, [imageKey]);
    // Nor is it ever read as a note.
    await expectLater(
      () => readQuicklogObject(client: client, key: imageKey),
      throwsArgumentError,
    );
  });

  test('--import streams notes only and keeps image objects', () async {
    // A real picture, a zero-byte one, a type v0.4.0 never wrote and a name
    // dressed up as a note: none of them may be emitted or deleted.
    final images = <String, List<int>>{
      'ql-img-260908-100000-123.jpg': [0xFF, 0xD8, 0xFF],
      'ql-img-260908-100000-124.png': const [],
      'ql-img-260908-100000-125.bmp': [0x42, 0x4D],
      'ql-img-260908-100000-126.md': [0x78],
    };
    for (final image in images.entries) {
      await client.putObject(image.key, image.value);
    }
    await client.putText('ql-260908-100000.md', 'note');
    final emitted = <String>[];

    final summary = await streamQuicklogObjects(
      client: client,
      emitNote: (key, content) async => emitted.add('$key:$content'),
      readAck: (_) async => ImportAck(ok: true),
    );

    expect(emitted, ['ql-260908-100000.md:note']);
    expect(summary.fetched, 1);
    expect(summary.deleted, 1);
    expect(summary.failed, 0);
    expect(client.objects, images);
  });

  group('listQuicklogKeys', () {
    test('filters, sorts oldest first, and applies limit', () async {
      await client.putText('ql-260908-100020.md', 'c');
      await client.putText('readme.txt', 'nope');
      await client.putText('ql-260908-100005.md', 'a');
      await client.putText('ql-260908-100010.md', 'b');

      final all = await listQuicklogKeys(client: client);
      expect(all, [
        'ql-260908-100005.md',
        'ql-260908-100010.md',
        'ql-260908-100020.md',
      ]);

      final limited = await listQuicklogKeys(client: client, limit: 2);
      expect(limited, ['ql-260908-100005.md', 'ql-260908-100010.md']);
    });

    test('empty bucket lists nothing', () async {
      expect(await listQuicklogKeys(client: client), isEmpty);
    });

    test(
      'onlyKeys filters after the ql-* filter and keeps sort order',
      () async {
        await client.putText('ql-260908-100021.md', 'a');
        await client.putText('ql-260908-100022.md', 'b');
        await client.putText('readme.txt', 'nope');

        expect(
          await listQuicklogKeys(
            client: client,
            onlyKeys: {'ql-260908-100022.md', 'not-in-bucket.md'},
          ),
          ['ql-260908-100022.md'],
        );
        expect(await listQuicklogKeys(client: client, onlyKeys: {}), isEmpty);
      },
    );
  });

  group('readQuicklogObject', () {
    test('reads a valid note key as text', () async {
      await client.putText('ql-260908-100030.md', 'héllo ✓');
      final text = await readQuicklogObject(
        client: client,
        key: 'ql-260908-100030.md',
      );
      expect(text, 'héllo ✓');
    });

    test('rejects non-quicklog keys without contacting S3', () async {
      await client.putText('secrets.txt', 'x');
      final callsBefore = client.calls;
      expect(
        () => readQuicklogObject(client: client, key: 'secrets.txt'),
        throwsArgumentError,
      );
      expect(client.calls, callsBefore);
    });

    test('missing object surfaces the error', () async {
      await expectLater(
        readQuicklogObject(client: client, key: 'ql-260908-100031.md'),
        throwsA(isA<S3MissingObjectError>()),
      );
    });

    test(
      'corrupt utf-8 decodes with replacement chars, not an error',
      () async {
        await client.putObject('ql-260908-100032.md', [
          0x71,
          0x6c,
          0xff,
          0xfe,
          0x20,
          0x6f,
          0x6b,
        ]);
        final text = await readQuicklogObject(
          client: client,
          key: 'ql-260908-100032.md',
        );
        expect(text, contains('ok'));
        expect(text, contains('\uFFFD'));
      },
    );
  });

  group('deleteQuicklogObjects', () {
    test('deletes each valid key', () async {
      await client.putText('ql-260908-100040.md', 'a');
      await client.putText('ql-260908-100041.md', 'b');
      final summary = await deleteQuicklogObjects(
        client: client,
        keys: ['ql-260908-100040.md', 'ql-260908-100041.md'],
      );
      expect(summary.deleted, 2);
      expect(summary.failed, 0);
      expect(client.objects, isEmpty);
    });

    test('refuses non-quicklog keys and continues with the rest', () async {
      await client.putText('ql-260908-100042.md', 'a');
      final messages = <String>[];
      final summary = await deleteQuicklogObjects(
        client: client,
        keys: ['secrets.txt', 'ql-260908-100042.md'],
        onError: messages.add,
      );
      expect(summary.deleted, 1);
      expect(summary.failed, 1);
      expect(messages.first, contains('refusing to delete'));
      expect(client.objects, isEmpty);
    });

    test('reports delete failures without aborting the batch', () async {
      final flaky = _DeleteFailsClient();
      await flaky.putText('ql-260908-100043.md', 'a');
      await flaky.putText('ql-260908-100044.md', 'b');
      final messages = <String>[];
      final summary = await deleteQuicklogObjects(
        client: flaky,
        keys: ['ql-260908-100043.md', 'ql-260908-100044.md'],
        onError: messages.add,
      );
      expect(summary.deleted, 0);
      expect(summary.failed, 2);
      expect(messages.length, 2);
      expect(flaky.objects.length, 2);
    });
  });

  group('parseAckLine', () {
    const key = 'ql-260908-100050.md';

    test('accepts ok and fail acks for the expected key', () {
      expect(
        parseAckLine('{"key":"$key","ok":true}', expectedKey: key)!.ok,
        isTrue,
      );
      expect(
        parseAckLine('{"key":"$key","ok":false}', expectedKey: key)!.ok,
        isFalse,
      );
    });

    test('tolerates trailing whitespace and CRLF line endings', () {
      // The consumer may be a shell printf or a text editor that appends a
      // CRLF — the ack must still parse (trim happens before decode).
      expect(
        parseAckLine('{"key":"$key","ok":true}  ', expectedKey: key)!.ok,
        isTrue,
      );
      expect(
        parseAckLine('{"key":"$key","ok":false}\r', expectedKey: key)!.ok,
        isFalse,
      );
      expect(
        parseAckLine('{"key":"$key","ok":true}\r\n', expectedKey: key)!.ok,
        isTrue,
      );
      expect(
        parseAckLine('\t{"key":"$key","ok":true}\r\n', expectedKey: key)!.ok,
        isTrue,
      );
    });

    test('null for EOF, garbage, key mismatch, or missing ok flag', () {
      expect(parseAckLine(null, expectedKey: key), isNull);
      expect(parseAckLine('', expectedKey: key), isNull);
      expect(parseAckLine('not json', expectedKey: key), isNull);
      expect(
        parseAckLine('{"key":"other.md","ok":true}', expectedKey: key),
        isNull,
      );
      expect(parseAckLine('{"key":"$key"}', expectedKey: key), isNull);
      expect(
        parseAckLine('{"key":"$key","ok":"yes"}', expectedKey: key),
        isNull,
      );
    });
  });

  group('streamQuicklogObjects', () {
    test('emits each note, deletes only acked ones, in key order', () async {
      await client.putText('ql-260908-100060.md', 'first');
      await client.putText('ql-260908-100061.md', 'second');
      final emitted = <String>[];
      final acked = <String>[];

      final summary = await streamQuicklogObjects(
        client: client,
        emitNote: (key, content) async => emitted.add('$key:$content'),
        readAck: (key) async {
          acked.add(key);
          return ImportAck(ok: true);
        },
      );

      expect(emitted, [
        'ql-260908-100060.md:first',
        'ql-260908-100061.md:second',
      ]);
      expect(acked, ['ql-260908-100060.md', 'ql-260908-100061.md']);
      expect(summary.fetched, 2);
      expect(summary.deleted, 2);
      expect(summary.failed, 0);
      expect(summary.aborted, isFalse);
      expect(summary.ok, isTrue);
      expect(client.objects, isEmpty);
    });

    test('ok:false ack keeps the object for retry and continues', () async {
      await client.putText('ql-260908-100062.md', 'bad');
      await client.putText('ql-260908-100063.md', 'good');
      final messages = <String>[];

      final summary = await streamQuicklogObjects(
        client: client,
        emitNote: (_, _) async {},
        readAck: (key) async => ImportAck(ok: key != 'ql-260908-100062.md'),
        onError: messages.add,
      );

      expect(summary.fetched, 1);
      expect(summary.deleted, 1);
      expect(summary.failed, 1);
      expect(summary.ok, isFalse);
      expect(messages.first, contains('kept for retry'));
      expect(client.objects.containsKey('ql-260908-100062.md'), isTrue);
      expect(client.objects.containsKey('ql-260908-100063.md'), isFalse);
    });

    test('null ack (consumer gone) aborts the run without deleting', () async {
      await client.putText('ql-260908-100064.md', 'a');
      await client.putText('ql-260908-100065.md', 'b');
      await client.putText('ql-260908-100066.md', 'c');
      var calls = 0;
      final messages = <String>[];

      final summary = await streamQuicklogObjects(
        client: client,
        emitNote: (_, _) async {},
        readAck: (key) async {
          calls++;
          // Consumer disappears after the second note: neither it nor any
          // later note may be deleted.
          return calls < 2 ? ImportAck(ok: true) : null;
        },
        onError: messages.add,
      );

      expect(summary.fetched, 1);
      expect(summary.deleted, 1);
      expect(summary.aborted, isTrue);
      expect(summary.ok, isFalse);
      expect(messages.any((m) => m.contains('consumer went away')), isTrue);
      // First note deleted; second and third survive for the next run.
      expect(client.objects.containsKey('ql-260908-100064.md'), isFalse);
      expect(client.objects.containsKey('ql-260908-100065.md'), isTrue);
      expect(client.objects.containsKey('ql-260908-100066.md'), isTrue);
    });

    test('read failure skips the note and continues', () async {
      final flaky = _ReadFailsClient();
      await flaky.putText('ql-260908-100067.md', 'a');
      await flaky.putText('ql-260908-100068.md', 'b');
      final messages = <String>[];

      final summary = await streamQuicklogObjects(
        client: flaky,
        emitNote: (_, _) async {},
        readAck: (key) async => ImportAck(ok: true),
        onError: messages.add,
      );

      expect(summary.fetched, 1);
      expect(summary.deleted, 1);
      expect(summary.failed, 1);
      expect(summary.aborted, isFalse);
      expect(messages.first, contains('read failed'));
      expect(flaky.objects.containsKey('ql-260908-100067.md'), isTrue);
      expect(flaky.objects.containsKey('ql-260908-100068.md'), isFalse);
    });

    test('bucket list error propagates so the CLI can fail loudly', () async {
      await client.putText('ql-260908-100069.md', 'a');
      client.alwaysFail = StateError('simulated list failure');

      await expectLater(
        streamQuicklogObjects(
          client: client,
          emitNote: (_, _) async {},
          readAck: (key) async => ImportAck(ok: true),
        ),
        throwsStateError,
      );
      expect(client.objects.containsKey('ql-260908-100069.md'), isTrue);
    });

    test(
      'emit failure skips the note and continues without deleting',
      () async {
        await client.putText('ql-260908-100072.md', 'a');
        await client.putText('ql-260908-100073.md', 'b');
        final messages = <String>[];

        final summary = await streamQuicklogObjects(
          client: client,
          emitNote: (key, _) async {
            if (key == 'ql-260908-100072.md') {
              throw StateError('simulated emit failure');
            }
          },
          readAck: (key) async => ImportAck(ok: true),
          onError: messages.add,
        );

        expect(summary.fetched, 1);
        expect(summary.deleted, 1);
        expect(summary.failed, 1);
        expect(summary.aborted, isFalse);
        expect(messages.first, contains('emit failed'));
        // The note whose emit failed was never acked or deleted.
        expect(client.objects.containsKey('ql-260908-100072.md'), isTrue);
        expect(client.objects.containsKey('ql-260908-100073.md'), isFalse);
      },
    );

    test(
      'delete failure after ok-ack keeps the object (documented duplicate window)',
      () async {
        // The note is imported and acked ok, but the delete fails, so the
        // next run re-emits it and the consumer's pending-description
        // dedup must suppress the duplicate lines. Without that dedup this
        // is the one accepted way a note can be imported twice.
        final flaky = _DeleteFailsClient();
        await flaky.putText('ql-260908-100074.md', 'imported but kept');
        final messages = <String>[];

        final summary = await streamQuicklogObjects(
          client: flaky,
          emitNote: (_, _) async {},
          readAck: (key) async => ImportAck(ok: true),
          onError: messages.add,
        );

        expect(summary.fetched, 1);
        expect(summary.deleted, 0);
        expect(summary.failed, 1);
        expect(summary.ok, isFalse);
        expect(messages.first, contains('delete failed for'));
        expect(flaky.objects.containsKey('ql-260908-100074.md'), isTrue);
      },
    );

    test('onlyKeys restricts streaming to the named keys', () async {
      await client.putText('ql-260908-100075.md', 'a');
      await client.putText('ql-260908-100076.md', 'b');
      final emitted = <String>[];

      final summary = await streamQuicklogObjects(
        client: client,
        emitNote: (key, _) async => emitted.add(key),
        readAck: (key) async => ImportAck(ok: true),
        onlyKeys: {'ql-260908-100075.md'},
      );

      expect(emitted, ['ql-260908-100075.md']);
      expect(summary.deleted, 1);
      // The unnamed key must survive untouched (E2E isolation contract).
      expect(client.objects.containsKey('ql-260908-100076.md'), isTrue);
    });

    test('limit caps how many notes are streamed', () async {
      await client.putText('ql-260908-100070.md', 'a');
      await client.putText('ql-260908-100071.md', 'b');
      final emitted = <String>[];

      final summary = await streamQuicklogObjects(
        client: client,
        emitNote: (key, _) async => emitted.add(key),
        readAck: (key) async => ImportAck(ok: true),
        limit: 1,
      );

      expect(emitted, ['ql-260908-100070.md']);
      expect(summary.deleted, 1);
      expect(client.objects.length, 1);
    });

    test('empty bucket emits nothing and is ok', () async {
      var emitted = 0;
      final summary = await streamQuicklogObjects(
        client: client,
        emitNote: (_, _) async => emitted++,
        readAck: (key) async => ImportAck(ok: true),
      );
      expect(emitted, 0);
      expect(summary.ok, isTrue);
    });
  });
}

class _DeleteFailsClient extends MemoryS3ObjectClient {
  @override
  Future<void> deleteObject(String key) async {
    throw StateError('simulated delete failure for $key');
  }
}

class _ReadFailsClient extends MemoryS3ObjectClient {
  @override
  Future<List<int>> getObject(String key) async {
    if (key == 'ql-260908-100067.md') {
      throw StateError('simulated read failure for $key');
    }
    return super.getObject(key);
  }
}
