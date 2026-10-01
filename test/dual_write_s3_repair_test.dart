import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:quicklog/screens/entry_browser_controller.dart';
import 'package:quicklog/services/active_note_store.dart';
import 'package:quicklog/services/browser_note_sources.dart';
import 'package:quicklog/services/dual_write_s3_repair.dart';
import 'package:quicklog/services/log_service.dart';
import 'package:quicklog/services/merged_note_listing.dart';
import 'package:quicklog/services/preferences.dart';
import 'package:quicklog/services/s3_note_store.dart';
import 'package:quicklog/services/s3_object_client.dart';
import 'package:quicklog/services/s3_session_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/memory_s3_object_client.dart';

LocatedLogEntry _remoteOnly(String noteId) => LocatedLogEntry(
  entry: LogEntry(id: noteId, timestamp: parseLogEntryId(noteId)!),
  location: NoteStorageLocation.s3,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const id = 'ql-260927-120000.md';

  LocatedLogEntry both(String noteId) => LocatedLogEntry(
    entry: LogEntry(id: noteId, timestamp: parseLogEntryId(noteId)!),
    location: NoteStorageLocation.both,
  );

  group('DualWriteS3Repair', () {
    late Directory tmp;
    late LocalNoteStore local;
    late MemoryS3ObjectClient client;
    late S3NoteStore s3;
    late DualWriteS3Repair repairs;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('ql-repair-');
      local = LocalNoteStore(tmp.path);
      client = MemoryS3ObjectClient();
      s3 = S3NoteStore(client);
      repairs = DualWriteS3Repair();
    });

    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    BrowserNoteSources sources() => BrowserNoteSources(
      local: local,
      s3: s3,
      mergeWhenS3Preferred: true,
      preferLocalReads: true,
      keepLocalCopies: true,
      pendingRepairs: repairs,
    );

    test('update with S3 down keeps local text and replay restores S3', () async {
      await File(p.join(tmp.path, id)).writeAsString('local old');
      await client.putText(id, 's3 old');
      client.failNext = Exception('put failed');

      await expectLater(
        sources().update(both(id), 'edited'),
        throwsA(isA<DualWriteS3Pending>()),
      );

      expect(await local.read(id), 'edited');
      expect(utf8.decode(client.objects[id]!), 's3 old');
      expect(await repairs.hasPending(), isTrue);

      final repaired = await repairs.replay(local: local, s3: s3);
      expect(repaired, 1);
      expect(utf8.decode(client.objects[id]!), 'edited');
      expect(await repairs.hasPending(), isFalse);
    });

    test('a later successful update drops the pending upload', () async {
      await File(p.join(tmp.path, id)).writeAsString('local old');
      await client.putText(id, 's3 old');
      client.failNext = Exception('put failed');
      await expectLater(
        sources().update(both(id), 'edited'),
        throwsA(
          isA<DualWriteS3Pending>().having(
            (e) => e.message,
            'message',
            contains('Saved on this device'),
          ),
        ),
      );

      await sources().update(both(id), 'edited again');

      expect(utf8.decode(client.objects[id]!), 'edited again');
      expect(await repairs.hasPending(), isFalse);
    });

    test('delete that misses S3 is finished by replay', () async {
      await File(p.join(tmp.path, id)).writeAsString('gone soon');
      await client.putText(id, 'still remote');
      client.failNext = Exception('delete failed');

      await expectLater(
        sources().delete(both(id)),
        throwsA(
          isA<DualWriteS3Pending>().having(
            (e) => e.message,
            'message',
            contains('not deleted'),
          ),
        ),
      );

      expect(File(p.join(tmp.path, id)).existsSync(), isFalse);
      expect(client.objects.containsKey(id), isTrue);

      await repairs.replay(local: local, s3: s3);

      expect(client.objects.containsKey(id), isFalse);
      expect(await repairs.hasPending(), isFalse);
    });

    test('delete replaces a pending upload for the same id', () async {
      await File(p.join(tmp.path, id)).writeAsString('local');
      await client.putText(id, 'remote');
      client.failNext = Exception('put failed');
      await expectLater(
        sources().update(both(id), 'edited'),
        throwsA(isA<DualWriteS3Pending>()),
      );
      client.failNext = Exception('delete failed');
      await expectLater(
        sources().delete(both(id)),
        throwsA(isA<DualWriteS3Pending>()),
      );

      await repairs.replay(local: local, s3: s3);

      expect(client.objects.containsKey(id), isFalse);
      expect(await repairs.hasPending(), isFalse);
    });

    test('a missing local file becomes a pending delete', () async {
      await client.putText(id, 'stale remote');
      await repairs.enqueueUpload(id);

      final repaired = await repairs.replay(local: local, s3: s3);

      expect(repaired, 1);
      expect(client.objects.containsKey(id), isFalse);
      expect(await repairs.hasPending(), isFalse);
    });

    test('an already-absent S3 object completes a pending delete', () async {
      await repairs.enqueueDelete(id);
      final gone = S3NoteStore(_AlwaysMissingDelete());

      final repaired = await repairs.replay(local: local, s3: gone);

      expect(repaired, 1);
      expect(await repairs.hasPending(), isFalse);
    });

    test('without a queue, S3 failure is the raw error and nothing is replayed',
        () async {
      await File(p.join(tmp.path, id)).writeAsString('local old');
      await client.putText(id, 's3 old');
      client.failNext = Exception('put failed');
      final plain = BrowserNoteSources(
        local: local,
        s3: s3,
        mergeWhenS3Preferred: true,
      );

      await expectLater(
        plain.update(both(id), 'edited'),
        throwsA(
          predicate<Object>(
            (e) => e is! DualWriteS3Pending && '$e'.contains('put failed'),
          ),
        ),
      );

      await plain.replayPendingS3();
      expect(await local.read(id), 'edited');
      expect(utf8.decode(client.objects[id]!), 's3 old');
    });

    test('replay leaves the id queued as an upload when the put still fails',
        () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'flutter.Directory': tmp.path,
      });
      final prefs = PreferencesService();
      final queued = DualWriteS3Repair(preferences: prefs);
      await File(p.join(tmp.path, id)).writeAsString('edited');
      await client.putText(id, 's3 old');
      await queued.enqueueUpload(id);
      client.failNext = Exception('put failed');

      final repaired = await queued.replay(local: local, s3: s3);

      expect(repaired, 0);
      expect(utf8.decode(client.objects[id]!), 's3 old');
      expect(await prefs.dualWritePendingUploads(), [id]);
      expect(await prefs.dualWritePendingDeletes(), isEmpty);

      await queued.replay(local: local, s3: s3);
      expect(utf8.decode(client.objects[id]!), 'edited');
      expect(await prefs.dualWritePendingUploads(), isEmpty);
    });

    test('a failed S3 list still queues an edit of the local row', () async {
      await File(p.join(tmp.path, id)).writeAsString('local old');
      await client.putText(id, 's3 old');
      client.failNext = Exception('list failed');
      final src = sources();
      final rows = await src.list();
      final row = rows.single;
      expect(src.s3ListFailed, isTrue);
      expect(row.isLocalOnly, isTrue);

      client.failNext = Exception('put failed');
      await expectLater(
        src.update(row, 'edited'),
        throwsA(isA<DualWriteS3Pending>()),
      );

      expect(await local.read(id), 'edited');
      expect(utf8.decode(client.objects[id]!), 's3 old');
      await repairs.replay(local: local, s3: s3);
      expect(utf8.decode(client.objects[id]!), 'edited');
      expect(await repairs.hasPending(), isFalse);
    });

    test('a failed S3 list still queues a delete of the local row', () async {
      await File(p.join(tmp.path, id)).writeAsString('gone soon');
      await client.putText(id, 'still remote');
      client.failNext = Exception('list failed');
      final src = sources();
      final row = (await src.list()).single;
      expect(row.isLocalOnly, isTrue);

      client.failNext = Exception('delete failed');
      await expectLater(
        src.delete(row),
        throwsA(isA<DualWriteS3Pending>()),
      );

      expect(File(p.join(tmp.path, id)).existsSync(), isFalse);
      expect(client.objects.containsKey(id), isTrue);
      await repairs.replay(local: local, s3: s3);
      expect(client.objects.containsKey(id), isFalse);
      expect(await repairs.hasPending(), isFalse);
    });

    test('local failure after an S3 put keeps the device text primary', () async {
      final failing = _FailingLocal(tmp.path);
      final src = BrowserNoteSources(
        local: failing,
        s3: s3,
        mergeWhenS3Preferred: true,
        preferLocalReads: true,
        keepLocalCopies: true,
        pendingRepairs: repairs,
      );
      await File(p.join(tmp.path, id)).writeAsString('local old');
      await client.putText(id, 's3 old');
      client.failNext = Exception('put failed');
      await expectLater(
        src.update(both(id), 'edited'),
        throwsA(isA<DualWriteS3Pending>()),
      );

      failing.fail = true;
      await expectLater(
        src.update(both(id), 'edited again'),
        throwsA(isA<FileSystemException>()),
      );

      expect(await local.read(id), 'edited');
      expect(utf8.decode(client.objects[id]!), 'edited again');
      expect(await repairs.hasPending(), isTrue);

      failing.fail = false;
      await repairs.replay(local: failing, s3: s3);
      expect(utf8.decode(client.objects[id]!), 'edited');
      expect(await repairs.hasPending(), isFalse);
    });

    test('a restored local file is uploaded instead of deleted', () async {
      await client.putText(id, 'remote');
      await repairs.enqueueDelete(id);
      await File(p.join(tmp.path, id)).writeAsString('restored');

      final repaired = await repairs.replay(local: local, s3: s3);

      expect(repaired, 1);
      expect(utf8.decode(client.objects[id]!), 'restored');
      expect(await repairs.hasPending(), isFalse);
    });

    test('text written during a replay stays queued and is put next', () async {
      final gated = _GatedPut();
      final remote = S3NoteStore(gated);
      await File(p.join(tmp.path, id)).writeAsString('v1');
      await gated.putText(id, 'v1');
      await repairs.enqueueUpload(id);
      final entered = Completer<void>();
      final release = Completer<void>();
      gated.entered = entered;
      gated.release = release;

      final replay = repairs.replay(local: local, s3: remote);
      await entered.future;
      await File(p.join(tmp.path, id)).writeAsString('v2');
      release.complete();
      await replay;

      expect(utf8.decode(gated.objects[id]!), 'v1');
      expect(await repairs.hasPending(), isTrue);

      final repaired = await repairs.replay(local: local, s3: remote);
      expect(repaired, 1);
      expect(utf8.decode(gated.objects[id]!), 'v2');
      expect(await repairs.hasPending(), isFalse);
    });

    test('a save during replay is the text that remains on S3', () async {
      final gated = _GatedPut();
      final remote = S3NoteStore(gated);
      await File(p.join(tmp.path, id)).writeAsString('v1');
      await gated.putText(id, 'v1');
      await repairs.enqueueUpload(id);
      final entered = Completer<void>();
      final release = Completer<void>();
      gated.entered = entered;
      gated.release = release;
      final src = BrowserNoteSources(
        local: local,
        s3: remote,
        mergeWhenS3Preferred: true,
        preferLocalReads: true,
        keepLocalCopies: true,
        pendingRepairs: repairs,
      );

      final replay = repairs.replay(local: local, s3: remote);
      await entered.future;
      final saved = src.update(both(id), 'v2');
      release.complete();
      await replay;
      await saved;

      expect(await local.read(id), 'v2');
      expect(utf8.decode(gated.objects[id]!), 'v2');
      expect(await repairs.hasPending(), isFalse);
    });

    test('a local delete that fails after the S3 delete is re-uploaded', () async {
      final failing = _FailingDeleteLocal(tmp.path);
      final src = BrowserNoteSources(
        local: failing,
        s3: s3,
        mergeWhenS3Preferred: true,
        preferLocalReads: true,
        keepLocalCopies: true,
        pendingRepairs: repairs,
      );
      await File(p.join(tmp.path, id)).writeAsString('keep me');
      await client.putText(id, 'remote');
      failing.fail = true;

      await expectLater(
        src.delete(both(id)),
        throwsA(isA<FileSystemException>()),
      );

      expect(File(p.join(tmp.path, id)).existsSync(), isTrue);
      expect(client.objects.containsKey(id), isFalse);
      expect(await repairs.hasPending(), isTrue);

      failing.fail = false;
      await repairs.replay(local: failing, s3: s3);
      expect(utf8.decode(client.objects[id]!), 'keep me');
      expect(await repairs.hasPending(), isFalse);
    });

    test('editing an S3 leftover cancels a queued delete', () async {
      await client.putText(id, 'stale remote');
      await repairs.enqueueDelete(id);
      final remoteOnly = LocatedLogEntry(
        entry: LogEntry(id: id, timestamp: parseLogEntryId(id)!),
        location: NoteStorageLocation.s3,
      );

      await sources().update(remoteOnly, 'edited on s3');

      expect(utf8.decode(client.objects[id]!), 'edited on s3');
      expect(await repairs.hasPending(), isFalse);
      await repairs.replay(local: local, s3: s3);
      expect(utf8.decode(client.objects[id]!), 'edited on s3');
    });

    test('a file restored during the S3 delete is put back', () async {
      final gated = _GatedDelete();
      final remote = S3NoteStore(gated);
      await gated.putText(id, 'remote');
      await repairs.enqueueDelete(id);
      final entered = Completer<void>();
      final release = Completer<void>();
      gated.entered = entered;
      gated.release = release;

      final replay = repairs.replay(local: local, s3: remote);
      await entered.future;
      await File(p.join(tmp.path, id)).writeAsString('restored');
      release.complete();
      await replay;

      expect(utf8.decode(gated.objects[id]!), 'restored');
      expect(await repairs.hasPending(), isFalse);
    });

    test('a missing notes directory does not delete the queued upload', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'flutter.Directory': tmp.path,
      });
      final prefs = PreferencesService();
      final queued = DualWriteS3Repair(preferences: prefs);
      await File(p.join(tmp.path, id)).writeAsString('keep');
      await client.putText(id, 'remote');
      await queued.enqueueUpload(id);
      await tmp.delete(recursive: true);

      final repaired = await queued.replay(
        local: LocalNoteStore(tmp.path),
        s3: s3,
      );

      expect(repaired, 0);
      expect(utf8.decode(client.objects[id]!), 'remote');
      expect(await prefs.dualWritePendingUploads(), [id]);
      expect(await prefs.dualWritePendingDeletes(), isEmpty);
    });

    test('an S3-only row with a device file is updated in both places', () async {
      await File(p.join(tmp.path, id)).writeAsString('device');
      await client.putText(id, 'remote');

      await sources().update(_remoteOnly(id), 'edited');

      expect(await local.read(id), 'edited');
      expect(utf8.decode(client.objects[id]!), 'edited');
    });

    test('an S3-only row with a device file is deleted in both places', () async {
      await File(p.join(tmp.path, id)).writeAsString('device');
      await client.putText(id, 'remote');

      await sources().delete(_remoteOnly(id));

      expect(File(p.join(tmp.path, id)).existsSync(), isFalse);
      expect(client.objects.containsKey(id), isFalse);
    });

    test('a lost put response keeps the edit and drops the queued delete', () async {
      await client.putText(id, 'old');
      await repairs.enqueueDelete(id);
      client.putSucceedsButThrows = Exception('lost response');

      await expectLater(
        sources().update(_remoteOnly(id), 'edited'),
        throwsA(
          predicate<Object>((e) => '$e'.contains('lost response')),
        ),
      );

      expect(utf8.decode(client.objects[id]!), 'edited');
      expect(await repairs.hasPending(), isFalse);
      await repairs.replay(local: local, s3: s3);
      expect(utf8.decode(client.objects[id]!), 'edited');
    });

    test('an S3-only row is read from the device file when it exists', () async {
      await File(p.join(tmp.path, id)).writeAsString('device text');
      await client.putText(id, 'bucket text');
      final src = sources();

      expect(await src.storeFor(_remoteOnly(id)).read(id), 'device text');
    });

    test('replay does not upload a same id from another notes folder', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'flutter.Directory': tmp.path,
      });
      final prefs = PreferencesService();
      final queued = DualWriteS3Repair(preferences: prefs);
      await File(p.join(tmp.path, id)).writeAsString('original edit');
      await client.putText(id, 'remote');
      await queued.enqueueUpload(id);
      final other = await Directory.systemTemp.createTemp('ql-other-');
      addTearDown(() async {
        if (await other.exists()) await other.delete(recursive: true);
      });
      await File(p.join(other.path, id)).writeAsString('other folder');

      final repaired = await queued.replay(
        local: LocalNoteStore(other.path),
        s3: s3,
      );

      expect(repaired, 0);
      expect(utf8.decode(client.objects[id]!), 'remote');
      expect(await prefs.dualWritePendingUploads(), [id]);

      final reloaded = DualWriteS3Repair(preferences: prefs);
      final again = await reloaded.replay(
        local: LocalNoteStore(other.path),
        s3: s3,
      );
      expect(again, 0);
      expect(utf8.decode(client.objects[id]!), 'remote');
      expect(await prefs.dualWritePendingUploads(), [id]);
    });

    test('a pending delete waits while its notes folder is missing', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'flutter.Directory': tmp.path,
      });
      final prefs = PreferencesService();
      final queued = DualWriteS3Repair(preferences: prefs);
      await client.putText(id, 'remote');
      await queued.enqueueDelete(id);
      await tmp.delete(recursive: true);

      final repaired = await queued.replay(
        local: LocalNoteStore(tmp.path),
        s3: s3,
      );

      expect(repaired, 0);
      expect(utf8.decode(client.objects[id]!), 'remote');
      expect(await prefs.dualWritePendingDeletes(), [id]);
    });

    test('a folder that vanishes during replay does not delete the upload', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'flutter.Directory': tmp.path,
      });
      final prefs = PreferencesService();
      final queued = DualWriteS3Repair(preferences: prefs);
      await client.putText(id, 'remote');
      await queued.enqueueUpload(id);

      final repaired = await queued.replay(
        local: _VanishFolderOnRead(tmp.path),
        s3: s3,
      );

      expect(repaired, 0);
      expect(utf8.decode(client.objects[id]!), 'remote');
      expect(await prefs.dualWritePendingUploads(), [id]);
      expect(await prefs.dualWritePendingDeletes(), isEmpty);
    });

    test('a folder that vanishes after the put does not delete the upload', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'flutter.Directory': tmp.path,
      });
      final prefs = PreferencesService();
      final queued = DualWriteS3Repair(preferences: prefs);
      await File(p.join(tmp.path, id)).writeAsString('edited');
      await client.putText(id, 'remote');
      await queued.enqueueUpload(id);

      final repaired = await queued.replay(
        local: _VanishFolderOnSecondRead(tmp.path),
        s3: s3,
      );

      expect(repaired, 0);
      expect(utf8.decode(client.objects[id]!), 'edited');
      expect(await prefs.dualWritePendingUploads(), [id]);
      expect(await prefs.dualWritePendingDeletes(), isEmpty);
    });

    test('a folder that vanishes during replay does not delete the queued object', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'flutter.Directory': tmp.path,
      });
      final prefs = PreferencesService();
      final queued = DualWriteS3Repair(preferences: prefs);
      await client.putText(id, 'remote');
      await queued.enqueueDelete(id);

      final repaired = await queued.replay(
        local: _VanishFolderOnRead(tmp.path),
        s3: s3,
      );

      expect(repaired, 0);
      expect(utf8.decode(client.objects[id]!), 'remote');
      expect(await prefs.dualWritePendingDeletes(), [id]);
      expect(await prefs.dualWritePendingUploads(), isEmpty);
    });

    test('a follow-up upload during replay stays in the folder being replayed', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'flutter.Directory': tmp.path,
      });
      final prefs = PreferencesService();
      final queued = DualWriteS3Repair(preferences: prefs);
      await File(p.join(tmp.path, id)).writeAsString('keep');
      await client.putText(id, 'remote');
      await queued.enqueueDelete(id);
      final other = await Directory.systemTemp.createTemp('ql-other-');
      addTearDown(() async {
        if (await other.exists()) await other.delete(recursive: true);
      });
      await prefs.setDirectory(other.path);
      client.failNext = Exception('put failed');

      await queued.replay(local: LocalNoteStore(tmp.path), s3: s3);

      final folders = await prefs.dualWritePendingFolders();
      expect(folders[tmp.path]?.uploads, [id]);
      expect(folders[tmp.path]?.deletes ?? const <String>[], isEmpty);
      expect(folders.containsKey(other.path), isFalse);
      expect(utf8.decode(client.objects[id]!), 'remote');
    });

    test('a delete that removed both copies completes when the S3 call throws', () async {
      final remoteClient = _DeleteThenThrow();
      final remote = S3NoteStore(remoteClient);
      final src = BrowserNoteSources(
        local: local,
        s3: remote,
        mergeWhenS3Preferred: true,
        preferLocalReads: true,
        keepLocalCopies: true,
        pendingRepairs: repairs,
      );
      await File(p.join(tmp.path, id)).writeAsString('gone');
      await remoteClient.putText(id, 'remote');

      await src.delete(both(id));

      expect(File(p.join(tmp.path, id)).existsSync(), isFalse);
      expect(remoteClient.objects.containsKey(id), isFalse);
      expect(await repairs.hasPending(), isFalse);
    });

    test('s3-only delete still throws when the missing-object error arrives late', () async {
      final remoteClient = _DeleteThenMissing();
      final remote = S3NoteStore(remoteClient);
      final src = BrowserNoteSources(
        local: local,
        s3: remote,
        mergeWhenS3Preferred: true,
      );
      await remoteClient.putText(id, 'remote');

      await expectLater(
        src.delete(_remoteOnly(id)),
        throwsA(isA<S3MissingObjectError>()),
      );

      expect(remoteClient.gets, 0);
      expect(remoteClient.objects.containsKey(id), isFalse);
    });

    test('a lost delete response during replay drops the repair', () async {
      final remoteClient = _DeleteThenThrow();
      final remote = S3NoteStore(remoteClient);
      await remoteClient.putText(id, 'remote');
      await repairs.enqueueDelete(id);

      final repaired = await repairs.replay(local: local, s3: remote);

      expect(repaired, 1);
      expect(remoteClient.objects.containsKey(id), isFalse);
      expect(await repairs.hasPending(), isFalse);
    });

    test('a folder that vanishes after restoring a delete stays a delete', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'flutter.Directory': tmp.path,
      });
      final prefs = PreferencesService();
      final queued = DualWriteS3Repair(preferences: prefs);
      await File(p.join(tmp.path, id)).writeAsString('keep');
      await client.putText(id, 'remote');
      await queued.enqueueDelete(id);

      final repaired = await queued.replay(
        local: _VanishFolderOnSecondRead(tmp.path),
        s3: s3,
      );

      expect(repaired, 0);
      expect(utf8.decode(client.objects[id]!), 'keep');
      expect(await prefs.dualWritePendingDeletes(), [id]);
      expect(await prefs.dualWritePendingUploads(), isEmpty);
    });

    test('a file removed after the restore put is deleted from the bucket', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'flutter.Directory': tmp.path,
      });
      final prefs = PreferencesService();
      final queued = DualWriteS3Repair(preferences: prefs);
      await File(p.join(tmp.path, id)).writeAsString('keep');
      await client.putText(id, 'remote');
      await queued.enqueueDelete(id);

      final repaired = await queued.replay(
        local: _DropFileOnSecondRead(tmp.path),
        s3: s3,
      );

      expect(repaired, 1);
      expect(client.objects.containsKey(id), isFalse);
      expect(await prefs.dualWritePendingDeletes(), isEmpty);
      expect(await prefs.dualWritePendingUploads(), isEmpty);
    });

    test('a corrupt repair list is left on disk when it cannot be loaded', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'flutter.Directory': tmp.path,
        'flutter.DualWritePending': '{',
      });
      final prefs = PreferencesService();
      final queued = DualWriteS3Repair(preferences: prefs);

      final repaired = await queued.replay(local: LocalNoteStore(tmp.path), s3: s3);
      await expectLater(
        queued.enqueueUpload(id),
        throwsA(isA<StateError>()),
      );
      await expectLater(
        queued.enqueueDelete(id),
        throwsA(isA<StateError>()),
      );

      expect(repaired, 0);
      final stored = await SharedPreferences.getInstance();
      expect(stored.getString('DualWritePending'), '{');
    });

    test('an unreadable repair document is not replaced by a new queue', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'flutter.Directory': tmp.path,
        'flutter.DualWritePending': '[]',
      });
      final queued = DualWriteS3Repair(preferences: PreferencesService());

      await expectLater(
        queued.enqueueUpload(id),
        throwsA(isA<StateError>()),
      );

      final stored = await SharedPreferences.getInstance();
      expect(stored.getString('DualWritePending'), '[]');
    });

    test('a non-list repair field is not overwritten', () async {
      final raw = jsonEncode(<String, Object>{
        'folders': <String, Object>{
          tmp.path: <String, Object>{'uploads': id, 'deletes': <String>[]},
        },
      });
      SharedPreferences.setMockInitialValues(<String, Object>{
        'flutter.Directory': tmp.path,
        'flutter.DualWritePending': raw,
      });
      final queued = DualWriteS3Repair(preferences: PreferencesService());

      await expectLater(
        queued.enqueueUpload('ql-260927-120001.md'),
        throwsA(isA<StateError>()),
      );

      final stored = await SharedPreferences.getInstance();
      expect(stored.getString('DualWritePending'), raw);
    });

    test('a legacy repair document still replays', () async {
      final raw = jsonEncode(<String, Object>{
        'directory': tmp.path,
        'uploads': <String>[id],
        'deletes': <String>[],
      });
      SharedPreferences.setMockInitialValues(<String, Object>{
        'flutter.Directory': tmp.path,
        'flutter.DualWritePending': raw,
      });
      final prefs = PreferencesService();
      final queued = DualWriteS3Repair(preferences: prefs);
      await File(p.join(tmp.path, id)).writeAsString('edited');
      await client.putText(id, 'remote');

      final repaired = await queued.replay(local: LocalNoteStore(tmp.path), s3: s3);

      expect(repaired, 1);
      expect(utf8.decode(client.objects[id]!), 'edited');
      expect(await prefs.dualWritePendingUploads(), isEmpty);
    });

    test('s3-only delete still throws a lost response without reading', () async {
      final remoteClient = _CountingDeleteThenThrow();
      final remote = S3NoteStore(remoteClient);
      final src = BrowserNoteSources(
        local: local,
        s3: remote,
        mergeWhenS3Preferred: true,
      );
      await remoteClient.putText(id, 'remote');

      await expectLater(
        src.delete(_remoteOnly(id)),
        throwsA(predicate<Object>((e) => '$e'.contains('lost delete'))),
      );

      expect(remoteClient.gets, 0);
      expect(remoteClient.objects.containsKey(id), isFalse);
    });

    test('a failed replay delete leaves the id queued', () async {
      await client.putText(id, 'remote');
      await repairs.enqueueDelete(id);
      client.failNext = Exception('delete failed');

      final repaired = await repairs.replay(local: local, s3: s3);

      expect(repaired, 0);
      expect(utf8.decode(client.objects[id]!), 'remote');
      expect(await repairs.hasPending(), isTrue);
    });

    test('an unreadable bucket after a lost replay delete stays queued', () async {
      final remoteClient = _DeleteThenUnreadable();
      final remote = S3NoteStore(remoteClient);
      remoteClient.objects[id] = utf8.encode('remote');
      await repairs.enqueueDelete(id);

      final repaired = await repairs.replay(local: local, s3: remote);

      expect(repaired, 0);
      expect(utf8.decode(remoteClient.objects[id]!), 'remote');
      expect(await repairs.hasPending(), isTrue);
    });

    test('a file restored during the confirmation delete is put back', () async {
      final remoteClient = _RestoreOnDelete(tmp.path);
      final remote = S3NoteStore(remoteClient);
      await File(p.join(tmp.path, id)).writeAsString('keep');
      await remoteClient.putText(id, 'remote');
      await repairs.enqueueDelete(id);

      final repaired = await repairs.replay(
        local: _MissSecondRead(tmp.path),
        s3: remote,
      );

      expect(repaired, 1);
      expect(utf8.decode(remoteClient.objects[id]!), 'back');
      expect(await repairs.hasPending(), isFalse);
      expect(await File(p.join(tmp.path, id)).readAsString(), 'back');
    });

    test('a folder that vanishes during the confirmation delete stays queued', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'flutter.Directory': tmp.path,
      });
      final prefs = PreferencesService();
      final queued = DualWriteS3Repair(preferences: prefs);
      final remoteClient = _DeleteFolderOnDelete(tmp.path);
      final remote = S3NoteStore(remoteClient);
      await File(p.join(tmp.path, id)).writeAsString('keep');
      await remoteClient.putText(id, 'remote');
      await queued.enqueueDelete(id);

      final repaired = await queued.replay(
        local: _MissSecondRead(tmp.path),
        s3: remote,
      );

      expect(repaired, 0);
      expect(remoteClient.objects.containsKey(id), isFalse);
      expect(await prefs.dualWritePendingDeletes(), [id]);
    });

    test('a file that disappears again after the put-back is deleted in this pass', () async {
      final remoteClient = _RestoreOnDelete(tmp.path);
      final remote = S3NoteStore(remoteClient);
      await File(p.join(tmp.path, id)).writeAsString('keep');
      await remoteClient.putText(id, 'remote');
      await repairs.enqueueDelete(id);

      final repaired = await repairs.replay(
        local: _MissReads({2, 4, 5}, tmp.path),
        s3: remote,
      );

      expect(repaired, 1);
      expect(remoteClient.objects.containsKey(id), isFalse);
      expect(await repairs.hasPending(), isFalse);
    });

    test('a lost replay delete whose follow-up read fails stays a delete', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'flutter.Directory': tmp.path,
      });
      final prefs = PreferencesService();
      final queued = DualWriteS3Repair(preferences: prefs);
      final remoteClient = _DeleteRemovedThenUnreadable();
      final remote = S3NoteStore(remoteClient);
      remoteClient.objects[id] = utf8.encode('remote');
      await queued.enqueueDelete(id);

      final repaired = await queued.replay(
        local: LocalNoteStore(tmp.path),
        s3: remote,
      );

      expect(repaired, 0);
      expect(remoteClient.objects.containsKey(id), isFalse);
      expect(await prefs.dualWritePendingDeletes(), [id]);
      expect(await prefs.dualWritePendingUploads(), isEmpty);
    });

    test('a failed bucket delete after the file disappears stays a delete', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'flutter.Directory': tmp.path,
      });
      final prefs = PreferencesService();
      final queued = DualWriteS3Repair(preferences: prefs);
      final remoteClient = _PutOkDeleteFails();
      final remote = S3NoteStore(remoteClient);
      await File(p.join(tmp.path, id)).writeAsString('keep');
      await remoteClient.putText(id, 'remote');
      await queued.enqueueDelete(id);

      final repaired = await queued.replay(
        local: _MissSecondRead(tmp.path),
        s3: remote,
      );

      expect(repaired, 0);
      expect(utf8.decode(remoteClient.objects[id]!), 'keep');
      expect(await prefs.dualWritePendingDeletes(), [id]);
      expect(await prefs.dualWritePendingUploads(), isEmpty);

      remoteClient.fail = false;
      final again = await queued.replay(
        local: LocalNoteStore(tmp.path),
        s3: remote,
      );

      expect(again, 1);
      expect(remoteClient.objects.containsKey(id), isFalse);
      expect(await prefs.dualWritePendingDeletes(), isEmpty);
    });

    test('a lost delete response still re-uploads the device file', () async {
      final failing = _FailingDeleteLocal(tmp.path);
      final remoteClient = _DeleteThenThrow();
      final remote = S3NoteStore(remoteClient);
      final src = BrowserNoteSources(
        local: failing,
        s3: remote,
        mergeWhenS3Preferred: true,
        preferLocalReads: true,
        keepLocalCopies: true,
        pendingRepairs: repairs,
      );
      await File(p.join(tmp.path, id)).writeAsString('keep me');
      await remoteClient.putText(id, 'remote');
      failing.fail = true;

      await expectLater(
        src.delete(both(id)),
        throwsA(predicate<Object>((e) => '$e'.contains('lost delete'))),
      );

      expect(File(p.join(tmp.path, id)).existsSync(), isTrue);
      expect(remoteClient.objects.containsKey(id), isFalse);
      expect(await repairs.hasPending(), isTrue);

      failing.fail = false;
      await repairs.replay(local: failing, s3: remote);
      expect(utf8.decode(remoteClient.objects[id]!), 'keep me');
      expect(await repairs.hasPending(), isFalse);
    });

    test('an unreadable bucket after a lost put does not delete the edit', () async {
      final remoteClient = _PutThenUnreadable();
      final remote = S3NoteStore(remoteClient);
      final src = BrowserNoteSources(
        local: local,
        s3: remote,
        mergeWhenS3Preferred: true,
        preferLocalReads: true,
        keepLocalCopies: true,
        pendingRepairs: repairs,
      );
      remoteClient.objects[id] = utf8.encode('old');
      await repairs.enqueueDelete(id);

      await expectLater(
        src.update(_remoteOnly(id), 'edited'),
        throwsA(predicate<Object>((e) => '$e'.contains('lost response'))),
      );

      expect(utf8.decode(remoteClient.objects[id]!), 'edited');
      expect(await repairs.hasPending(), isFalse);
      await repairs.replay(local: local, s3: remote);
      expect(utf8.decode(remoteClient.objects[id]!), 'edited');
    });

    test('repair lists share one preference value', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'flutter.Directory': tmp.path,
      });
      final prefs = PreferencesService();
      const other = 'ql-260927-120001.md';
      await prefs.setDualWritePendingFolders({
        tmp.path: (uploads: [id], deletes: const [other]),
      });

      final stored = await SharedPreferences.getInstance();
      final raw = stored.getString('DualWritePending');
      expect(raw, contains(id));
      expect(raw, contains(other));
      expect(stored.getStringList('DualWritePendingUploads'), isNull);
      expect(stored.getStringList('DualWritePendingDeletes'), isNull);
      expect(await prefs.dualWritePendingUploads(), [id]);
      expect(await prefs.dualWritePendingDeletes(), [other]);
    });
  });

  group('ActiveNoteStore dual-write repair', () {
    late Directory tmp;
    late PreferencesService prefs;
    late S3SessionController session;
    late MemoryS3ObjectClient client;
    late ActiveNoteStore active;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('ql-repair-active-');
      SharedPreferences.setMockInitialValues(<String, Object>{
        'flutter.Directory': tmp.path,
        'flutter.StorageMode': 'both',
        'flutter.S3AccessKeyId': 'AKIA_TEST',
        'flutter.S3SecretAccessKey': 'secret_test',
      });
      prefs = PreferencesService();
      session = S3SessionController(preferences: prefs);
      await session.load();
      client = MemoryS3ObjectClient();
      active = ActiveNoteStore(
        preferences: prefs,
        session: session,
        s3ClientFactory: (_) => client,
      );
    });

    tearDown(() async {
      session.dispose();
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    Future<void> seedBoth(String localText, String remoteText) async {
      await File(p.join(tmp.path, id)).writeAsString(localText);
      await client.putText(id, remoteText);
    }

    Future<String> readLocal() => File(p.join(tmp.path, id)).readAsString();

    test('pending upload is persisted and replayed on browser refresh', () async {
      await seedBoth('local old', 's3 old');
      final sources = await active.resolveBrowserSources();
      expect(sources.pendingRepairs, isNotNull);
      client.failNext = Exception('put failed');
      await expectLater(
        sources.update(both(id), 'edited'),
        throwsA(isA<DualWriteS3Pending>()),
      );
      expect(await prefs.dualWritePendingUploads(), [id]);

      final restarted = DualWriteS3Repair(preferences: prefs);
      expect(await restarted.hasPending(), isTrue);

      final browser = EntryBrowserController(
        session: session,
        activeStore: active,
        preferences: prefs,
      );
      browser.refresh();
      await browser.future;
      browser.dispose();

      expect(utf8.decode(client.objects[id]!), 'edited');
      expect(await prefs.dualWritePendingUploads(), isEmpty);
    });

    test('refresh while degraded leaves the stale S3 object queued', () async {
      await seedBoth('local old', 's3 old');
      final sources = await active.resolveBrowserSources();
      client.failNext = Exception('put failed');
      await expectLater(
        sources.update(both(id), 'edited'),
        throwsA(isA<DualWriteS3Pending>()),
      );
      await session.markS3Failed();

      final browser = EntryBrowserController(
        session: session,
        activeStore: active,
        preferences: prefs,
      );
      browser.refresh();
      await browser.future;
      browser.dispose();

      expect(utf8.decode(client.objects[id]!), 's3 old');
      expect(await prefs.dualWritePendingUploads(), [id]);
    });

    test('retryS3 reachable replays a pending upload', () async {
      await seedBoth('local old', 's3 old');
      final sources = await active.resolveBrowserSources();
      client.failNext = Exception('put failed');
      await expectLater(
        sources.update(both(id), 'edited'),
        throwsA(isA<DualWriteS3Pending>()),
      );
      await session.markS3Failed();

      final result = await session.retryS3(probe: () async {});

      expect(result, S3RetryResult.reachable);
      expect(utf8.decode(client.objects[id]!), 'edited');
      expect(await prefs.dualWritePendingUploads(), isEmpty);
    });

    test('degrade-window end replays a pending upload', () async {
      var now = DateTime.utc(2026, 9, 27, 12);
      final clocked = S3SessionController(
        preferences: prefs,
        clock: () => now,
      );
      await clocked.load();
      await clocked.setPreferredMode(StorageMode.both);
      final clockedActive = ActiveNoteStore(
        preferences: prefs,
        session: clocked,
        s3ClientFactory: (_) => client,
      );
      addTearDown(clocked.dispose);

      await seedBoth('local old', 's3 old');
      final sources = await clockedActive.resolveBrowserSources();
      final recovered = Completer<void>();
      final replay = clocked.onRecovered!;
      clocked.onRecovered = () async {
        await replay();
        recovered.complete();
      };
      client.failNext = Exception('put failed');
      await expectLater(
        sources.update(both(id), 'edited'),
        throwsA(isA<DualWriteS3Pending>()),
      );
      await clocked.markS3Failed(now: now);

      now = now.add(kS3DegradeDuration);
      expect(clocked.isDegraded, isFalse);
      await recovered.future;

      expect(utf8.decode(client.objects[id]!), 'edited');
      expect(await prefs.dualWritePendingUploads(), isEmpty);
    });

    test('s3-only update failure does not queue or replay', () async {
      await session.setPreferredMode(StorageMode.s3);
      await seedBoth('local old', 's3 old');
      final sources = await active.resolveBrowserSources();
      expect(sources.pendingRepairs, isNull);
      expect(sources.keepLocalCopies, isFalse);
      client.failNext = Exception('put failed');

      await expectLater(
        sources.update(both(id), 'edited'),
        throwsA(
          predicate<Object>(
            (e) => e is! DualWriteS3Pending && '$e'.contains('put failed'),
          ),
        ),
      );

      expect(await readLocal(), 'edited');
      expect(utf8.decode(client.objects[id]!), 's3 old');
      expect(await prefs.dualWritePendingUploads(), isEmpty);
      expect(await prefs.dualWritePendingDeletes(), isEmpty);

      final browser = EntryBrowserController(
        session: session,
        activeStore: active,
        preferences: prefs,
      );
      browser.refresh();
      await browser.future;
      browser.dispose();
      await active.replayDualWriteRepairs();

      expect(utf8.decode(client.objects[id]!), 's3 old');
      expect(await prefs.dualWritePendingUploads(), isEmpty);
    });
  });
}

/// Removes the object, then reports it missing, and counts follow-up reads.
class _DeleteThenMissing extends MemoryS3ObjectClient {
  var gets = 0;

  @override
  Future<void> deleteObject(String key) async {
    objects.remove(key);
    throw S3MissingObjectError(key);
  }

  @override
  Future<List<int>> getObject(String key) async {
    gets++;
    return super.getObject(key);
  }
}

/// Removes the object, then throws, and counts follow-up reads.
class _CountingDeleteThenThrow extends MemoryS3ObjectClient {
  var gets = 0;

  @override
  Future<void> deleteObject(String key) async {
    objects.remove(key);
    throw Exception('lost delete');
  }

  @override
  Future<List<int>> getObject(String key) async {
    gets++;
    return super.getObject(key);
  }
}

/// Leaves the object in place, then both the delete and the follow-up read fail.
class _DeleteThenUnreadable extends MemoryS3ObjectClient {
  @override
  Future<void> deleteObject(String key) async {
    throw Exception('lost delete');
  }

  @override
  Future<List<int>> getObject(String key) async {
    throw Exception('read failed');
  }
}

/// Deletes the object, then writes the device file back.
class _RestoreOnDelete extends MemoryS3ObjectClient {
  _RestoreOnDelete(this.directory);

  final String directory;

  @override
  Future<void> deleteObject(String key) async {
    objects.remove(key);
    await File(p.join(directory, key)).writeAsString('back');
  }
}

/// Deletes the object and then the notes folder.
class _DeleteFolderOnDelete extends MemoryS3ObjectClient {
  _DeleteFolderOnDelete(this.directory);

  final String directory;

  @override
  Future<void> deleteObject(String key) async {
    objects.remove(key);
    await Directory(directory).delete(recursive: true);
  }
}

/// Puts succeed. Deletes fail until [fail] is cleared, and leave the object.
class _PutOkDeleteFails extends MemoryS3ObjectClient {
  bool fail = true;

  @override
  Future<void> deleteObject(String key) async {
    if (fail) throw Exception('delete failed');
    objects.remove(key);
  }
}

/// Removes the object, then the follow-up read fails.
class _DeleteRemovedThenUnreadable extends MemoryS3ObjectClient {
  @override
  Future<void> deleteObject(String key) async {
    objects.remove(key);
    throw Exception('lost delete');
  }

  @override
  Future<List<int>> getObject(String key) async {
    throw Exception('read failed');
  }
}

/// Reports the file missing on the given 1-based read numbers.
class _MissReads extends LocalNoteStore {
  _MissReads(this.missOn, super.directory);

  final Set<int> missOn;
  var reads = 0;

  @override
  Future<String> read(String id) async {
    reads++;
    if (missOn.contains(reads)) {
      final file = File(p.join(directory, id));
      if (await file.exists()) await file.delete();
      throw PathNotFoundException(
        p.join(directory, id),
        const OSError('No such file or directory', 2),
      );
    }
    return super.read(id);
  }
}

/// Reads once, then reports the file missing on the second read only.
class _MissSecondRead extends LocalNoteStore {
  _MissSecondRead(super.directory);

  var _reads = 0;

  @override
  Future<String> read(String id) async {
    _reads++;
    if (_reads == 2) {
      final file = File(p.join(directory, id));
      if (await file.exists()) await file.delete();
      throw PathNotFoundException(
        p.join(directory, id),
        const OSError('No such file or directory', 2),
      );
    }
    return super.read(id);
  }
}

/// Removes the object, then throws, as a delete whose response was lost.
class _DeleteThenThrow extends MemoryS3ObjectClient {
  @override
  Future<void> deleteObject(String key) async {
    objects.remove(key);
    throw Exception('lost delete');
  }
}

/// Stores the object, then throws, and the following read also fails.
class _PutThenUnreadable extends MemoryS3ObjectClient {
  @override
  Future<void> putObject(
    String key,
    List<int> bytes, {
    String contentType = 'text/markdown',
  }) async {
    objects[key] = List<int>.from(bytes);
    throw Exception('lost response');
  }

  @override
  Future<List<int>> getObject(String key) async {
    throw Exception('read failed');
  }
}

/// Deletes the notes folder on the first read, then reports the file missing.
class _VanishFolderOnRead extends LocalNoteStore {
  _VanishFolderOnRead(super.directory);

  @override
  Future<String> read(String id) async {
    await Directory(directory).delete(recursive: true);
    throw PathNotFoundException(
      p.join(directory, id),
      const OSError('No such file or directory', 2),
    );
  }
}

/// Reads once, then deletes the file so the confirmation read fails.
class _DropFileOnSecondRead extends LocalNoteStore {
  _DropFileOnSecondRead(super.directory);

  var _reads = 0;

  @override
  Future<String> read(String id) async {
    _reads++;
    if (_reads >= 2) {
      final file = File(p.join(directory, id));
      if (await file.exists()) await file.delete();
      throw PathNotFoundException(
        p.join(directory, id),
        const OSError('No such file or directory', 2),
      );
    }
    return super.read(id);
  }
}

/// Reads once, then deletes the notes folder so the confirmation read fails.
class _VanishFolderOnSecondRead extends LocalNoteStore {
  _VanishFolderOnSecondRead(super.directory);

  var _reads = 0;

  @override
  Future<String> read(String id) async {
    _reads++;
    if (_reads >= 2) {
      await Directory(directory).delete(recursive: true);
      throw PathNotFoundException(
        p.join(directory, id),
        const OSError('No such file or directory', 2),
      );
    }
    return super.read(id);
  }
}

class _FailingDeleteLocal extends LocalNoteStore {
  _FailingDeleteLocal(super.directory);

  bool fail = false;

  @override
  Future<void> delete(String id) async {
    if (fail) throw const FileSystemException('denied');
    await super.delete(id);
  }
}

/// Removes the object, then waits, so a test can restore the local file
/// while the delete is still in flight.
class _GatedDelete extends MemoryS3ObjectClient {
  Completer<void>? entered;
  Completer<void>? release;

  @override
  Future<void> deleteObject(String key) async {
    objects.remove(key);
    final started = entered;
    final wait = release;
    entered = null;
    release = null;
    if (started != null && !started.isCompleted) started.complete();
    if (wait != null) await wait.future;
  }
}

class _FailingLocal extends LocalNoteStore {
  _FailingLocal(super.directory);

  bool fail = false;

  @override
  Future<void> update(String id, String text) async {
    if (fail) throw const FileSystemException('denied');
    await super.update(id, text);
  }
}

/// Holds the next [putObject] until [release] completes.
class _GatedPut extends MemoryS3ObjectClient {
  Completer<void>? entered;
  Completer<void>? release;

  @override
  Future<void> putObject(
    String key,
    List<int> bytes, {
    String contentType = 'text/markdown',
  }) async {
    final started = entered;
    final wait = release;
    entered = null;
    release = null;
    if (started != null && !started.isCompleted) started.complete();
    if (wait != null) await wait.future;
    await super.putObject(key, bytes, contentType: contentType);
  }
}

/// DELETE always reports the object as already gone.
class _AlwaysMissingDelete extends MemoryS3ObjectClient {
  @override
  Future<void> deleteObject(String key) async {
    throw S3MissingObjectError(key);
  }
}
