import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:quicklog/services/log_service.dart';
import 'package:quicklog/services/merged_note_listing.dart';
import 'package:quicklog/services/s3_note_store.dart';
import 'package:quicklog/services/s3_object_client.dart';

void main() {
  group('mergeNoteLists', () {
    LogEntry e(String id) =>
        LogEntry(id: id, timestamp: parseLogEntryId(id)!);

    test('unions local-only, s3-only, and both', () {
      final local = [
        e('ql-260901-100000.md'),
        e('ql-260901-120000.md'), // also in s3
      ];
      final s3 = [
        e('ql-260901-120000.md'),
        e('ql-260901-140000.md'),
      ];
      final merged = mergeNoteLists(local: local, s3: s3);
      expect(merged.map((x) => x.id).toList(), [
        'ql-260901-140000.md',
        'ql-260901-120000.md',
        'ql-260901-100000.md',
      ]);
      expect(merged[0].location, NoteStorageLocation.s3);
      expect(merged[1].location, NoteStorageLocation.both);
      expect(merged[2].location, NoteStorageLocation.local);
    });

    test('empty sides yield empty or single-source lists', () {
      expect(mergeNoteLists(local: const [], s3: const []), isEmpty);
      final onlyLocal = mergeNoteLists(
        local: [e('ql-260901-100000.md')],
        s3: const [],
      );
      expect(onlyLocal.single.location, NoteStorageLocation.local);
    });
  });

  group('moveLocalNoteToS3', () {
    late Directory tmp;
    late LocalNoteStore local;
    late MemoryS3ObjectClient client;
    late S3NoteStore s3;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('ql-move-');
      local = LocalNoteStore(tmp.path);
      client = MemoryS3ObjectClient();
      s3 = S3NoteStore(client);
    });

    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test('uploads then deletes local', () async {
      final entry = await local.create(
        'hello s3',
        now: DateTime(2026, 9, 1, 10, 0, 0),
      );
      expect(File(p.join(tmp.path, entry.id)).existsSync(), isTrue);

      await moveLocalNoteToS3(local: local, s3: s3, id: entry.id);

      expect(File(p.join(tmp.path, entry.id)).existsSync(), isFalse);
      expect(await s3.read(entry.id), 'hello s3');
    });

    test('keeps local when S3 put fails', () async {
      final entry = await local.create(
        'stay local',
        now: DateTime(2026, 9, 1, 11, 0, 0),
      );
      client.alwaysFail = Exception('put failed');

      await expectLater(
        moveLocalNoteToS3(local: local, s3: s3, id: entry.id),
        throwsA(isA<Exception>()),
      );
      expect(File(p.join(tmp.path, entry.id)).existsSync(), isTrue);
      expect(client.objects, isEmpty);
    });
  });
}
