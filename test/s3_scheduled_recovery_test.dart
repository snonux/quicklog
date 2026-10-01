import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quicklog/services/active_note_store.dart';
import 'package:quicklog/services/log_service.dart';
import 'package:quicklog/services/merged_note_listing.dart';
import 'package:quicklog/services/preferences.dart';
import 'package:quicklog/services/s3_config.dart';
import 'package:quicklog/services/s3_operation_lease.dart';
import 'package:quicklog/services/s3_note_store.dart';
import 'package:quicklog/services/s3_session_controller.dart';
import 'package:quicklog/services/s3_upload_receipts.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/memory_s3_object_client.dart';

class _Remote extends MemoryS3ObjectClient {
  Future<void> Function()? afterList;
  Future<void> Function(String key)? afterPut;
  Future<void> Function(String key)? beforePut;
  @override
  Future<List<String>> listKeys({String prefix = ''}) async {
    final result = await super.listKeys(prefix: prefix);
    await afterList?.call();
    return result;
  }

  @override
  Future<void> putObject(
    String key,
    List<int> bytes, {
    String contentType = 'text/markdown',
  }) async {
    await beforePut?.call(key);
    await super.putObject(key, bytes, contentType: contentType);
    await afterPut?.call(key);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late LocalNoteStore local;
  late PreferencesService prefs;
  late S3SessionController session;
  late _Remote remote;
  late ActiveNoteStore active;
  const leaseChannel = MethodChannel('ql-lease-test');

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('ql-scheduled-');
    SharedPreferences.setMockInitialValues({
      'flutter.Directory': directory.path,
      'flutter.StorageMode': 's3',
      'flutter.S3AccessKeyId': 'test',
      'flutter.S3SecretAccessKey': 'test',
    });
    local = LocalNoteStore(directory.path);
    prefs = PreferencesService();
    session = S3SessionController(preferences: prefs);
    await session.load();
    remote = _Remote();
    active = ActiveNoteStore(
      preferences: prefs,
      session: session,
      s3ClientFactory: (_) => remote,
    );
  });
  tearDown(() async {
    session.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(leaseChannel, null);
    await directory.delete(recursive: true);
  });

  test(
    'scheduled retry ignores degradation only when there are pending local notes',
    () async {
      await session.markS3Failed();
      await active.replayS3OnlyLocalNotes(retryWhileDegraded: true);
      expect(remote.calls, 0);
      expect(session.isDegraded, isTrue);
      final entry = await local.create('pending', now: DateTime(2026, 10, 1));
      await active.replayS3OnlyLocalNotes(retryWhileDegraded: true);
      expect(utf8.decode(remote.objects[entry.id]!), 'pending');
      expect(session.isDegraded, isFalse);
      expect(await local.read(entry.id), 'pending');
    },
  );

  test(
    'confirmed receipts prevent any traffic after remote drain and survive restart',
    () async {
      final entry = await local.create('note', now: DateTime(2026, 10, 1));
      await active.replayS3OnlyLocalNotes();
      remote.objects.clear();
      remote.calls = 0;
      active = ActiveNoteStore(
        preferences: prefs,
        session: session,
        s3ClientFactory: (_) => remote,
      );
      await active.replayS3OnlyLocalNotes(retryWhileDegraded: true);
      expect(remote.calls, 0);
      expect(remote.objects, isEmpty);
      await local.update(entry.id, 'edited after drain');
      await active.replayS3OnlyLocalNotes(retryWhileDegraded: true);
      expect(utf8.decode(remote.objects[entry.id]!), 'edited after drain');
    },
  );

  test(
    'existing remote acknowledges retained baseline without overwriting newer remote',
    () async {
      final entry = await local.create('old local', now: DateTime(2026, 10, 1));
      await remote.putText(entry.id, 'new remote');
      await active.replayS3OnlyLocalNotes();
      expect(utf8.decode(remote.objects[entry.id]!), 'new remote');
      remote.objects.clear();
      remote.calls = 0;
      await active.replayS3OnlyLocalNotes(retryWhileDegraded: true);
      expect(remote.calls, 0);
    },
  );

  test(
    'actual uploaded snapshot receipt leaves an edit during PUT pending',
    () async {
      final entry = await local.create(
        'sent snapshot',
        now: DateTime(2026, 10, 1),
      );
      remote.afterPut = (_) => local.update(entry.id, 'new local edit');
      await active.replayS3OnlyLocalNotes();
      expect(utf8.decode(remote.objects[entry.id]!), 'sent snapshot');
      final receipts = S3UploadReceipts(preferences: prefs);
      final scope = S3UploadReceipts.scope(
        await prefs.s3Config(),
        directory.path,
      );
      expect(
        await receipts.pending(scope: scope, local: local, entries: [entry]),
        [entry],
      );
      remote.afterPut = null;
      remote.objects.clear();
      await active.replayS3OnlyLocalNotes(retryWhileDegraded: true);
      expect(utf8.decode(remote.objects[entry.id]!), 'new local edit');
      remote.calls = 0;
      remote.objects.clear();
      await active.replayS3OnlyLocalNotes(retryWhileDegraded: true);
      expect(remote.calls, 0);
    },
  );

  test(
    'callback confirms the helper reread payload rather than earlier text',
    () async {
      String? acknowledged;
      await copyTextToS3IfMissing(
        s3: S3NoteStore(remote),
        id: 'ql-261001-000000.md',
        text: 'earlier',
        readCurrentText: () async => 'actual payload',
        onConfirmed: (text) async {
          acknowledged = text;
        },
      );
      expect(acknowledged, 'actual payload');
      expect(
        utf8.decode(remote.objects['ql-261001-000000.md']!),
        'actual payload',
      );
    },
  );

  test('settings changed while LIST awaits prevents scheduled PUT', () async {
    await local.create('pending', now: DateTime(2026, 10, 1));
    var current = true;
    remote.afterList = () async {
      current = false;
    };
    await active.replayS3OnlyLocalNotes(
      retryWhileDegraded: true,
      stillCurrent: () async => current,
    );
    expect(remote.objects, isEmpty);
  });

  test(
    'paused foreground-only expiry hook makes no requests, resume recovers',
    () async {
      await local.create('pending', now: DateTime(2026, 10, 1));
      var foreground = false;
      active.automaticRecoveryAllowed = () => foreground;
      active.bindSessionProbe();
      await session.onRecovered!();
      expect(remote.calls, 0);
      foreground = true;
      await session.onRecovered!();
      expect(remote.objects, isNotEmpty);
    },
  );

  test(
    'native busy create immediately saves durably, browser mutation reports busy',
    () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            leaseChannel,
            (call) async => call.method == 'acquire' ? false : null,
          );
      active = ActiveNoteStore(
        preferences: prefs,
        session: session,
        s3ClientFactory: (_) => remote,
        operationLeaseFactory: () =>
            S3OperationLease(channel: leaseChannel, android: true),
      );
      final result = await active.createNote(
        'safe',
        now: DateTime(2026, 10, 1),
      );
      expect(result.outcome, NoteCreateOutcome.savedLocalOnly);
      expect(await local.read(result.entry.id), 'safe');
      expect(await prefs.dualWritePendingUploads(), [result.entry.id]);
      final sources = await active.resolveBrowserSources();
      final row = (await sources.list()).single;
      await expectLater(
        sources.update(row, 'edit'),
        throwsA(isA<S3OperationBusy>()),
      );
      expect(await local.read(row.id), 'safe');
      expect(remote.objects, isEmpty);
    },
  );

  test(
    'direct new save never mistakes a retained old local baseline for an edit',
    () async {
      final stamp = DateTime(2026, 10, 1);
      final entry = await local.create('stale local', now: stamp);
      await active.createNote('new remote', now: stamp);
      await active.replayS3OnlyLocalNotes();
      expect(utf8.decode(remote.objects[entry.id]!), 'new remote');
      expect(await local.read(entry.id), 'stale local');
      remote.objects.clear();
      remote.calls = 0;
      await active.replayS3OnlyLocalNotes(retryWhileDegraded: true);
      expect(remote.calls, 0);
    },
  );

  test(
    'explicit pending upload takes precedence over a matching receipt',
    () async {
      final entry = await local.create('queued', now: DateTime(2026, 10, 1));
      final scope = S3UploadReceipts.scope(
        await prefs.s3Config(),
        directory.path,
      );
      await S3UploadReceipts(
        preferences: prefs,
      ).confirm(scope, entry.id, 'queued');
      await prefs.setDualWritePendingFolders({
        directory.path: (uploads: [entry.id], deletes: []),
      });
      await active.replayS3OnlyLocalNotes();
      expect(utf8.decode(remote.objects[entry.id]!), 'queued');
      expect(await prefs.dualWritePendingUploads(), isEmpty);
    },
  );

  test(
    'transient native release failure retries without changing acknowledged success',
    () async {
      var releases = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(leaseChannel, (call) async {
            if (call.method == 'acquire') return true;
            releases++;
            if (releases == 1) throw PlatformException(code: 'transient');
            return null;
          });
      active = ActiveNoteStore(
        preferences: prefs,
        session: session,
        s3ClientFactory: (_) => remote,
        operationLeaseFactory: () =>
            S3OperationLease(channel: leaseChannel, android: true),
      );
      final result = await active.createNote(
        'saved',
        now: DateTime(2026, 10, 1),
      );
      expect(result.outcome, NoteCreateOutcome.saved);
      await active.replayS3OnlyLocalNotes();
      expect(releases, greaterThanOrEqualTo(2));
      expect(utf8.decode(remote.objects[result.entry.id]!), 'saved');
    },
  );

  for (final android in [true, false]) {
    for (final operation in ['create', 'edit', 'delete']) {
      test(
        '${android ? 'Android' : 'desktop'} lease preserves newer dual $operation during an older worker PUT',
        () async {
          var held = false;
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(leaseChannel, (call) async {
                if (call.method == 'acquire') {
                  if (held) return false;
                  held = true;
                  return true;
                }
                held = false;
                return null;
              });
          active = ActiveNoteStore(
            preferences: prefs,
            session: session,
            s3ClientFactory: (_) => remote,
            operationLeaseFactory: () =>
                S3OperationLease(channel: leaseChannel, android: android),
          );
          final stamp = DateTime(2026, 10, 1);
          final entry = await local.create('worker snapshot', now: stamp);
          await remote.putText(entry.id, 'earlier remote');
          await prefs.setDualWritePendingFolders({
            directory.path: (uploads: [entry.id], deletes: []),
          });
          final entered = Completer<void>();
          final release = Completer<void>();
          remote.beforePut = (_) async {
            entered.complete();
            await release.future;
          };
          final worker = active.replayS3OnlyLocalNotes(
            retryWhileDegraded: true,
          );
          await entered.future;
          await session.setPreferredMode(StorageMode.both);
          final sources = await active.resolveBrowserSources();
          final row = (await sources.list()).single;
          if (operation == 'create') {
            final result = await active.createNote('new dual', now: stamp);
            expect(result.outcome, NoteCreateOutcome.savedLocalOnly);
          } else if (operation == 'edit') {
            await expectLater(sources.update(row, 'new dual'), throwsException);
          } else {
            await expectLater(sources.delete(row), throwsException);
          }
          expect(session.isDegraded, isFalse);
          remote.beforePut = null;
          release.complete();
          await worker;
          await active.replayDualWriteRepairs();
          if (operation == 'delete') {
            expect(remote.objects.containsKey(entry.id), isFalse);
            expect(await local.list(), isEmpty);
            expect(await prefs.dualWritePendingDeletes(), isEmpty);
          } else {
            expect(utf8.decode(remote.objects[entry.id]!), 'new dual');
            expect(await local.read(entry.id), 'new dual');
            expect(await prefs.dualWritePendingUploads(), isEmpty);
          }
        },
      );
    }
  }

  test('failed scheduled LIST rearms failure and keeps notes', () async {
    final entry = await local.create('safe', now: DateTime(2026, 10, 1));
    remote.alwaysFail = StateError('offline');
    await active.replayS3OnlyLocalNotes(retryWhileDegraded: true);
    expect(session.isDegraded, isTrue);
    expect(await local.read(entry.id), 'safe');
  });

  test(
    'changed bucket or local folder gets an independent receipt scope',
    () async {
      final entry = await local.create('safe', now: DateTime(2026, 10, 1));
      await active.replayS3OnlyLocalNotes();
      remote.objects.clear();
      await prefs.setS3Config(
        S3Config.fromRaw(
          bucket: 'other',
          accessKeyId: 'test',
          secretAccessKey: 'test',
        ),
      );
      await active.replayS3OnlyLocalNotes();
      expect(remote.objects.containsKey(entry.id), isTrue);
    },
  );
}
