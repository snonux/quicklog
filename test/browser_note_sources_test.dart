import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:quicklog/services/active_note_store.dart';
import 'package:quicklog/services/log_service.dart';
import 'package:quicklog/services/merged_note_listing.dart';
import 'package:quicklog/services/s3_note_store.dart';
import 'package:quicklog/services/s3_object_client.dart';

void main() {
  late Directory tmp;
  late LocalNoteStore local;
  late MemoryS3ObjectClient client;
  late S3NoteStore s3;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('ql-browser-src-');
    local = LocalNoteStore(tmp.path);
    client = MemoryS3ObjectClient();
    s3 = S3NoteStore(client);
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  LocatedLogEntry located(String id, NoteStorageLocation location) =>
      LocatedLogEntry(
        entry: LogEntry(id: id, timestamp: parseLogEntryId(id)!),
        location: location,
      );

  test('update of both writes local and S3', () async {
    const id = 'ql-260901-100000.md';
    await File(p.join(tmp.path, id)).writeAsString('local old');
    await client.putText(id, 's3 old');
    final sources = BrowserNoteSources(
      local: local,
      s3: s3,
      mergeWhenS3Preferred: true,
    );

    await sources.update(located(id, NoteStorageLocation.both), 'synced');

    expect(await local.read(id), 'synced');
    expect(await s3.read(id), 'synced');
  });

  test('entryStore update keeps both in sync', () async {
    const id = 'ql-260901-110000.md';
    await File(p.join(tmp.path, id)).writeAsString('a');
    await client.putText(id, 'b');
    final sources = BrowserNoteSources(
      local: local,
      s3: s3,
      mergeWhenS3Preferred: true,
    );
    final store = sources.entryStore(located(id, NoteStorageLocation.both));

    await store.update(id, 'from editor');

    expect(await local.read(id), 'from editor');
    expect(await s3.read(id), 'from editor');
  });

  test('delete of both removes local and S3', () async {
    const id = 'ql-260901-120000.md';
    await File(p.join(tmp.path, id)).writeAsString('x');
    await client.putText(id, 'x');
    final sources = BrowserNoteSources(
      local: local,
      s3: s3,
      mergeWhenS3Preferred: true,
    );

    await sources.delete(located(id, NoteStorageLocation.both));

    expect(File(p.join(tmp.path, id)).existsSync(), isFalse);
    expect(client.objects.containsKey(id), isFalse);
  });

  test('removeLocalCopy drops only the local file', () async {
    const id = 'ql-260901-130000.md';
    await File(p.join(tmp.path, id)).writeAsString('dup');
    await client.putText(id, 'dup');
    final sources = BrowserNoteSources(
      local: local,
      s3: s3,
      mergeWhenS3Preferred: true,
    );

    await sources.removeLocalCopy(located(id, NoteStorageLocation.both));

    expect(File(p.join(tmp.path, id)).existsSync(), isFalse);
    expect(await s3.read(id), 'dup');
  });

  test('removeLocalCopy rejects local-only notes', () async {
    final sources = BrowserNoteSources(
      local: local,
      s3: s3,
      mergeWhenS3Preferred: true,
    );
    await expectLater(
      sources.removeLocalCopy(
        located('ql-260901-140000.md', NoteStorageLocation.local),
      ),
      throwsStateError,
    );
  });

  test('moveLocalToS3 rejects notes that are not local-only', () async {
    final sources = BrowserNoteSources(
      local: local,
      s3: s3,
      mergeWhenS3Preferred: true,
    );
    await expectLater(
      sources.moveLocalToS3(
        located('ql-260901-150000.md', NoteStorageLocation.s3),
      ),
      throwsStateError,
    );
  });

  test('list sets s3ListFailed when S3 LIST throws', () async {
    await File(p.join(tmp.path, 'ql-260901-160000.md'))
        .writeAsString('still local');
    client.alwaysFail = Exception('list down');
    final sources = BrowserNoteSources(
      local: local,
      s3: s3,
      mergeWhenS3Preferred: true,
    );

    final listed = await sources.list();

    expect(sources.s3ListFailed, isTrue);
    expect(listed, hasLength(1));
    expect(listed.single.location, NoteStorageLocation.local);
  });

  test('list without merge does not set s3ListFailed', () async {
    final sources = BrowserNoteSources(
      local: local,
      mergeWhenS3Preferred: false,
    );
    final listed = await sources.list();
    expect(sources.s3ListFailed, isFalse);
    expect(listed, isEmpty);
  });

  test('update of both still writes local when S3 update fails', () async {
    const id = 'ql-260901-170000.md';
    await File(p.join(tmp.path, id)).writeAsString('local old');
    await client.putText(id, 's3 old');
    final sources = BrowserNoteSources(
      local: local,
      s3: s3,
      mergeWhenS3Preferred: true,
    );
    client.failNext = Exception('s3 update failed');

    await expectLater(
      sources.update(located(id, NoteStorageLocation.both), 'new text'),
      throwsA(isA<Exception>()),
    );
    expect(await local.read(id), 'new text');
    expect(await s3.read(id), 's3 old');
  });

  test('moveLocalToS3 rejects both-location notes', () async {
    final sources = BrowserNoteSources(
      local: local,
      s3: s3,
      mergeWhenS3Preferred: true,
    );
    await expectLater(
      sources.moveLocalToS3(
        located('ql-260901-180000.md', NoteStorageLocation.both),
      ),
      throwsStateError,
    );
  });
}
