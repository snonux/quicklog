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

    test('replay leaves the id queued when the put still fails', () async {
      await File(p.join(tmp.path, id)).writeAsString('edited');
      await client.putText(id, 's3 old');
      await repairs.enqueueUpload(id);
      client.failNext = Exception('put failed');

      final repaired = await repairs.replay(local: local, s3: s3);

      expect(repaired, 0);
      expect(utf8.decode(client.objects[id]!), 's3 old');
      expect(await repairs.hasPending(), isTrue);

      // A failed put must stay an upload. Recasting it as a delete would
      // remove the object on the next replay.
      await repairs.replay(local: local, s3: s3);
      expect(utf8.decode(client.objects[id]!), 'edited');
      expect(await repairs.hasPending(), isFalse);
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
      client.failNext = Exception('put failed');
      await expectLater(
        sources.update(both(id), 'edited'),
        throwsA(isA<DualWriteS3Pending>()),
      );
      await clocked.markS3Failed(now: now);

      now = now.add(kS3DegradeDuration);
      expect(clocked.isDegraded, isFalse);
      await pumpEventQueue();

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
