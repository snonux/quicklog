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
        throwsA(isNot(isA<DualWriteS3Pending>())),
      );

      await plain.replayPendingS3();
      expect(await local.read(id), 'edited');
      expect(utf8.decode(client.objects[id]!), 's3 old');
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
        throwsA(isNot(isA<DualWriteS3Pending>())),
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

/// DELETE always reports the object as already gone.
class _AlwaysMissingDelete extends MemoryS3ObjectClient {
  @override
  Future<void> deleteObject(String key) async {
    throw S3MissingObjectError(key);
  }
}
