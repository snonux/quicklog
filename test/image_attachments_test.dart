import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:quicklog/services/active_note_store.dart';
import 'package:quicklog/services/image_attachments.dart';
import 'package:quicklog/services/log_service.dart';
import 'package:quicklog/services/preferences.dart';
import 'package:quicklog/services/s3_note_store.dart';
import 'package:quicklog/services/s3_object_client.dart';
import 'package:quicklog/services/s3_session_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/memory_s3_object_client.dart';

/// Records [ImageAttachmentStore.write] calls; [error] makes them fail.
class _RecordingImageStore implements ImageAttachmentStore {
  final Map<String, Uint8List> written = {};
  Object? error;

  @override
  Future<void> write(String id, Uint8List bytes) async {
    final e = error;
    if (e != null) throw e;
    written[id] = bytes;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final now = DateTime(2026, 10, 8, 21, 5, 9, 42);
  const id = 'ql-img-261008-210509-042.jpg';
  final bytes = Uint8List.fromList([0xff, 0xd8, 0xff, 0xe0, 1, 2, 3]);

  group('naming', () {
    test('ids carry the timestamp to the millisecond', () {
      expect(imageAttachmentIdFor(now, 'jpg'), id);
      expect(isImageAttachmentId(id), isTrue);
    });

    test('ids never parse as notes, so note listings skip them', () {
      expect(parseLogEntryId(id), isNull);
    });

    test('extensions are normalised and unknown types become jpg', () {
      expect(imageExtensionFor('IMG_1.JPEG'), 'jpg');
      expect(imageExtensionFor('shot.png'), 'png');
      expect(imageExtensionFor('a.webp'), 'webp');
      expect(imageExtensionFor('scaled_1234'), 'jpg');
      expect(imageExtensionFor('evil.svg'), 'jpg');
    });

    test('path-like names are rejected', () {
      for (final bad in [
        '../$id',
        '/tmp/$id',
        'ql-img-261008-210509-042.md',
        'ql-261008-210509.md',
      ]) {
        expect(() => requireImageAttachmentId(bad), throwsArgumentError);
      }
    });
  });

  group('insertImageLink', () {
    TextEditingController at(String text, int offset) =>
        TextEditingController(text: text)
          ..selection = TextSelection.collapsed(offset: offset);

    test('into an empty note', () {
      final c = at('', 0);
      insertImageLink(c, id);
      expect(c.text, '![]($id)\n');
      expect(c.selection.baseOffset, c.text.length);
    });

    test('mid-line puts the link on its own line', () {
      final c = at('before after', 6);
      insertImageLink(c, id);
      expect(c.text, 'before\n![]($id)\n after');
      expect(c.selection.baseOffset, 'before\n![]($id)\n'.length);
    });

    test('at the start of a line does not add blank lines', () {
      final c = at('one\n\ntwo', 4);
      insertImageLink(c, id);
      expect(c.text, 'one\n![]($id)\ntwo');
    });

    test('replaces a selection', () {
      final c = TextEditingController(text: 'a\nXX\nb')
        ..selection = const TextSelection(baseOffset: 2, extentOffset: 4);
      insertImageLink(c, id);
      expect(c.text, 'a\n![]($id)\nb');
    });

    test('without a selection appends', () {
      final c = TextEditingController(text: 'note');
      insertImageLink(c, id);
      expect(c.text, 'note\n![]($id)\n');
    });
  });

  group('LocalImageAttachmentStore', () {
    late Directory tmp;
    setUp(() async => tmp = await Directory.systemTemp.createTemp('ql-img-'));
    tearDown(() async => tmp.delete(recursive: true));

    test('writes the bytes, creating the directory', () async {
      final dir = p.join(tmp.path, 'new');
      await LocalImageAttachmentStore(dir).write(id, bytes);
      expect(await File(p.join(dir, id)).readAsBytes(), bytes);
      expect(await LocalNoteStore(dir).list(), isEmpty);
    });

    test('never overwrites an existing image', () async {
      final file = File(p.join(tmp.path, id));
      await file.writeAsString('older');
      await expectLater(
        LocalImageAttachmentStore(tmp.path).write(id, bytes),
        throwsA(isA<FileSystemException>()),
      );
      expect(await file.readAsString(), 'older');
    });
  });

  test('SafImageAttachmentStore sends the bytes and MIME type', () async {
    const channel = MethodChannel('org.buetow.quicklog/saf-image-test');
    MethodCall? received;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          received = call;
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );

    await SafImageAttachmentStore(
      'content://tree/notes',
      channel: channel,
    ).write('ql-img-261008-210509-042.png', bytes);

    expect(received!.method, 'writeImage');
    final args = received!.arguments as Map;
    expect(args['treeUri'], 'content://tree/notes');
    expect(args['id'], 'ql-img-261008-210509-042.png');
    expect(args['mimeType'], 'image/png');
    expect(args['bytes'], bytes);
  });

  test('S3NoteStore listing skips image objects', () async {
    final s3 = MemoryS3ObjectClient();
    await S3ImageAttachmentStore(s3).write(id, bytes);
    await s3.putObject('ql-261008-210509.md', [0x61]);
    final entries = await S3NoteStore(s3).list();
    expect(entries.map((e) => e.id), ['ql-261008-210509.md']);
    expect(s3.objects[id], bytes);
  });

  group('ActiveNoteStore.saveImage', () {
    late Directory tmp;
    late S3SessionController session;
    late MemoryS3ObjectClient fakeS3;
    late _RecordingImageStore saf;
    Object? factoryError;

    Future<ActiveNoteStore> storeFor(
      StorageMode mode, {
      bool credentials = true,
      bool blockLocal = false,
      bool scoped = false,
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
      if (scoped) {
        await prefs.setScopedFolder('content://tree/vault', 'Vault');
      }
      session = S3SessionController(preferences: prefs);
      await session.load();
      return ActiveNoteStore(
        preferences: prefs,
        session: session,
        s3ClientFactory: (_) {
          final error = factoryError;
          if (error != null) throw error;
          return fakeS3;
        },
        safImageStoreFactory: (uri) {
          expect(uri, 'content://tree/vault');
          return saf;
        },
      );
    }

    bool localExists() => File(p.join(tmp.path, id)).existsSync();

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('ql-save-image-');
      fakeS3 = MemoryS3ObjectClient();
      saf = _RecordingImageStore();
      factoryError = null;
    });

    tearDown(() async {
      session.dispose();
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test('local mode writes the local directory only', () async {
      final active = await storeFor(StorageMode.local);
      final result = await active.saveImage(bytes, 'jpg', now: now);
      expect(result.id, id);
      expect(result.outcome, NoteCreateOutcome.saved);
      expect(localExists(), isTrue);
      expect(fakeS3.calls, 0);
    });

    test('local mode with a selected SAF folder writes there', () async {
      final active = await storeFor(StorageMode.local, scoped: true);
      final result = await active.saveImage(bytes, 'jpg', now: now);
      expect(result.outcome, NoteCreateOutcome.saved);
      expect(saf.written.keys, [id]);
      expect(localExists(), isFalse);
    });

    test('local mode surfaces a local failure', () async {
      final active = await storeFor(StorageMode.local, blockLocal: true);
      await expectLater(
        active.saveImage(bytes, 'jpg', now: now),
        throwsA(isA<FileSystemException>()),
      );
    });

    test('s3 mode puts the image in the bucket', () async {
      final active = await storeFor(StorageMode.s3);
      final result = await active.saveImage(bytes, 'jpg', now: now);
      expect(result.outcome, NoteCreateOutcome.saved);
      expect(fakeS3.objects[id], bytes);
      expect(localExists(), isFalse);
    });

    test('s3 mode, S3 down: kept locally and S3 is skipped', () async {
      final active = await storeFor(StorageMode.s3);
      fakeS3.alwaysFail = Exception('network down');
      final result = await active.saveImage(bytes, 'jpg', now: now);
      expect(result.outcome, NoteCreateOutcome.savedLocalOnly);
      expect(localExists(), isTrue);
      expect(session.isDegraded, isTrue);
    });

    test('s3 mode, invalid settings: kept locally, no degrade', () async {
      final active = await storeFor(StorageMode.s3);
      factoryError = const S3ConfigException('bad endpoint');
      final result = await active.saveImage(bytes, 'jpg', now: now);
      expect(result.outcome, NoteCreateOutcome.savedLocalS3SettingsInvalid);
      expect(localExists(), isTrue);
      expect(session.isDegraded, isFalse);
    });

    test('s3 mode while degraded never contacts S3', () async {
      final active = await storeFor(StorageMode.s3);
      await session.markS3Failed();
      final result = await active.saveImage(bytes, 'jpg', now: now);
      expect(result.outcome, NoteCreateOutcome.savedLocalOnly);
      expect(fakeS3.calls, 0);
      expect(localExists(), isTrue);
    });

    test('dual mode writes both', () async {
      final active = await storeFor(StorageMode.both);
      final result = await active.saveImage(bytes, 'jpg', now: now);
      expect(result.outcome, NoteCreateOutcome.saved);
      expect(fakeS3.objects[id], bytes);
      expect(localExists(), isTrue);
    });

    test('dual mode, local fails: S3 only', () async {
      final active = await storeFor(StorageMode.both, blockLocal: true);
      final result = await active.saveImage(bytes, 'jpg', now: now);
      expect(result.outcome, NoteCreateOutcome.savedS3Only);
      expect(fakeS3.objects[id], bytes);
    });

    test('dual mode, S3 down: local only', () async {
      final active = await storeFor(StorageMode.both);
      fakeS3.alwaysFail = Exception('network down');
      final result = await active.saveImage(bytes, 'jpg', now: now);
      expect(result.outcome, NoteCreateOutcome.savedLocalOnly);
      expect(localExists(), isTrue);
    });

    test('dual mode, both fail: the local error surfaces', () async {
      final active = await storeFor(StorageMode.both, blockLocal: true);
      fakeS3.alwaysFail = Exception('network down');
      await expectLater(
        active.saveImage(bytes, 'jpg', now: now),
        throwsA(isA<FileSystemException>()),
      );
    });
  });
}
