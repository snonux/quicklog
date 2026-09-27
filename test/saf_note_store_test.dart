import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quicklog/services/saf_note_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('org.buetow.quicklog/saf-test');
  const uri = 'content://notes/tree/vault';
  late SafNoteStore store;
  late Map<String, String> notes;
  late bool granted;
  late int calls;

  setUp(() {
    notes = {};
    granted = true;
    calls = 0;
    store = SafNoteStore(uri, channel: channel);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls++;
          final args = Map<String, String>.from(call.arguments as Map);
          expect(args['treeUri'], uri);
          if (!granted) {
            throw PlatformException(
              code: 'access_denied',
              message: 'Grant revoked',
            );
          }
          final id = args['id'];
          switch (call.method) {
            case 'list':
              return [...notes.keys, 'other.md', '../ql-260101-000000.md'];
            case 'create':
              if (notes.containsKey(id)) {
                throw PlatformException(code: 'io', message: 'Note exists');
              }
              notes[id!] = args['text']!;
              return null;
            case 'read':
              if (!notes.containsKey(id)) {
                throw PlatformException(code: 'not_found', message: 'Missing');
              }
              return notes[id];
            case 'update':
              if (!notes.containsKey(id)) {
                throw PlatformException(code: 'not_found', message: 'Missing');
              }
              notes[id!] = args['text']!;
              return null;
            case 'delete':
              notes.remove(id);
              return null;
          }
          throw MissingPluginException();
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test(
    'creates, lists, reads, edits, and deletes the same note identity',
    () async {
      final entry = await store.create(
        'first\nsecond',
        now: DateTime(2026, 5, 7, 14, 30, 45),
      );
      expect(entry.id, 'ql-260507-143045.md');
      expect(await store.firstLine(entry.id), 'first');
      expect(await store.preview(entry.id, maxChars: 5), 'first…');
      expect(await store.read(entry.id), 'first\nsecond');
      expect((await store.list()).map((e) => e.id), [entry.id]);

      await store.update(entry.id, 'edited');
      expect(await store.read(entry.id), 'edited');
      expect(await store.list(), hasLength(1));
      await store.delete(entry.id);
      expect(await store.list(), isEmpty);
    },
  );

  test(
    'listing sorts valid names and ignores unrelated provider documents',
    () async {
      notes['ql-260101-000000.md'] = 'old';
      notes['ql-260102-000000.md'] = 'new';
      expect((await store.list()).map((e) => e.id), [
        'ql-260102-000000.md',
        'ql-260101-000000.md',
      ]);
    },
  );

  test('rejects unsafe ids before calling Android', () async {
    for (final id in [
      '../ql-260101-000000.md',
      '/ql-260101-000000.md',
      'a.md',
    ]) {
      await expectLater(store.read(id), throwsArgumentError);
      await expectLater(store.update(id, 'x'), throwsArgumentError);
      await expectLater(store.delete(id), throwsArgumentError);
    }
    expect(calls, 0);
  });

  test('missing update fails without creating a note', () async {
    await expectLater(
      store.update('ql-260101-000000.md', 'replacement'),
      throwsA(
        isA<PlatformException>().having((e) => e.code, 'code', 'not_found'),
      ),
    );
    expect(notes, isEmpty);
  });

  test('provider collision does not overwrite a note', () async {
    notes['ql-260101-000000.md'] = 'keep';
    await expectLater(
      store.create('replacement', now: DateTime(2026, 1, 1)),
      throwsA(isA<PlatformException>().having((e) => e.code, 'code', 'io')),
    );
    expect(notes['ql-260101-000000.md'], 'keep');
  });

  test('revoked grant fails visibly and preserves existing notes', () async {
    notes['ql-260101-000000.md'] = 'original';
    granted = false;
    final denied = isA<PlatformException>().having(
      (e) => e.code,
      'code',
      'access_denied',
    );
    await expectLater(store.list(), throwsA(denied));
    await expectLater(store.read('ql-260101-000000.md'), throwsA(denied));
    await expectLater(
      store.update('ql-260101-000000.md', 'lost'),
      throwsA(denied),
    );
    await expectLater(store.delete('ql-260101-000000.md'), throwsA(denied));
    expect(await store.firstLine('ql-260101-000000.md'), '');
    await expectLater(store.preview('ql-260101-000000.md'), throwsA(denied));
    expect(notes['ql-260101-000000.md'], 'original');
  });
}
