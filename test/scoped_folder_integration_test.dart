import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quicklog/services/active_note_store.dart';
import 'package:quicklog/services/preferences.dart';
import 'package:quicklog/services/s3_session_controller.dart';
import 'package:quicklog/services/saf_note_store.dart';
import 'package:quicklog/services/s3_config.dart';
import 'package:quicklog/services/settings_backup.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/memory_s3_object_client.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('org.buetow.quicklog/saf-integration-test');
  const treeA = 'content://notes/tree/a';
  const treeB = 'content://notes/tree/b';
  late Directory path;
  late PreferencesService prefs;
  late S3SessionController session;
  late ActiveNoteStore active;
  late MemoryS3ObjectClient s3;
  late Map<String, Map<String, String>> trees;
  late Set<String> grants;

  setUp(() async {
    path = await Directory.systemTemp.createTemp('ql-scoped-');
    SharedPreferences.setMockInitialValues({'flutter.Directory': path.path});
    prefs = PreferencesService();
    session = S3SessionController(preferences: prefs);
    await session.load();
    s3 = MemoryS3ObjectClient();
    trees = {treeA: {}, treeB: {}};
    grants = {treeA, treeB};
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          final args = Map<String, String>.from(call.arguments as Map);
          final uri = args['treeUri']!;
          if (!grants.contains(uri)) {
            throw PlatformException(
              code: 'access_denied',
              message: 'Grant revoked',
            );
          }
          final notes = trees[uri]!;
          final id = args['id'];
          switch (call.method) {
            case 'list':
              return notes.keys.toList();
            case 'create':
              notes[id!] = args['text']!;
              return null;
            case 'read':
              if (!notes.containsKey(id)) {
                throw PlatformException(code: 'not_found');
              }
              return notes[id];
            case 'firstLine':
              return notes[id]?.split('\n').first ?? '';
            case 'update':
              notes[id!] = args['text']!;
              return null;
            case 'delete':
              notes.remove(id);
              return null;
          }
          throw MissingPluginException();
        });
    active = ActiveNoteStore(
      preferences: prefs,
      session: session,
      safStoreFactory: (uri) => SafNoteStore(uri, channel: channel),
      s3ClientFactory: (_) => s3,
    );
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    session.dispose();
    await path.delete(recursive: true);
  });

  test(
    'switches local writes and browser edits between path and selected tree',
    () async {
      final time = DateTime(2026, 9, 28, 8);
      final pathEntry = (await active.createNote('path', now: time)).entry;
      expect(await File('${path.path}/${pathEntry.id}').readAsString(), 'path');

      await prefs.setScopedFolder(treeA, 'Vault A');
      final scopedEntry = (await active.createNote(
        'scoped',
        now: time.add(const Duration(seconds: 1)),
      )).entry;
      expect(trees[treeA]![scopedEntry.id], 'scoped');
      expect(await active.resolveLocal(), isA<SafNoteStore>());
      final sources = await active.resolveBrowserSources();
      final row = (await sources.list()).single;
      await sources.entryStore(row).update('edited');
      expect(trees[treeA]![scopedEntry.id], 'edited');
      await sources.entryStore(row).delete();
      expect(trees[treeA], isEmpty);

      await prefs.clearScopedFolder();
      expect(
        (await active.resolveBrowserSources()).local.list().then(
          (v) => v.single.id,
        ),
        completion(pathEntry.id),
      );
    },
  );

  test(
    'revoked grant fails local and S3 fallback without writing to typed path',
    () async {
      await prefs.setScopedFolder(treeA, 'Vault A');
      grants.remove(treeA);
      await expectLater(
        active.createNote('lost'),
        throwsA(isA<PlatformException>()),
      );
      await expectLater(
        active.listForBrowser(),
        throwsA(isA<PlatformException>()),
      );
      expect(await path.list().toList(), isEmpty);

      await session.setPreferredMode(StorageMode.s3);
      await session.markS3Failed();
      await expectLater(
        active.createNote('still lost'),
        throwsA(isA<PlatformException>()),
      );
      expect(await path.list().toList(), isEmpty);
    },
  );

  test('S3-only degraded fallback saves in the selected tree', () async {
    await prefs.setScopedFolder(treeA, 'Vault A');
    await session.setPreferredMode(StorageMode.s3);
    await session.markS3Failed();
    final saved = await active.createNote(
      'offline',
      now: DateTime(2026, 9, 28, 10),
    );
    expect(saved.outcome, NoteCreateOutcome.savedLocalOnly);
    expect(trees[treeA]![saved.entry.id], 'offline');
    expect(await path.list().toList(), isEmpty);
  });

  test('dual-write S3 failure leaves a SAF copy and queues its tree', () async {
    await prefs.setScopedFolder(treeA, 'Vault A');
    await prefs.setS3Config(
      const S3Config(
        endpoint: kDefaultS3Endpoint,
        region: kDefaultS3Region,
        bucket: kDefaultS3Bucket,
        accessKeyId: 'test',
        secretAccessKey: 'secret',
      ),
    );
    await session.setPreferredMode(StorageMode.both);
    s3.alwaysFail = Exception('offline');
    final saved = await active.createNote(
      'local survives',
      now: DateTime(2026, 9, 28, 11),
    );
    expect(saved.outcome, NoteCreateOutcome.savedLocalOnly);
    expect(trees[treeA]![saved.entry.id], 'local survives');
    expect(await path.list().toList(), isEmpty);
    s3.alwaysFail = null;
    await session.retryS3();
    await s3.putText(saved.entry.id, 'remote old');
    final sources = await active.resolveBrowserSources();
    final row = (await sources.list()).single;
    s3.alwaysFail = Exception('offline again');
    await expectLater(sources.update(row, 'edited locally'), throwsException);
    expect(trees[treeA]![row.id], 'edited locally');
    expect((await prefs.dualWritePendingFolders())['saf:$treeA']?.uploads, [
      row.id,
    ]);
  });

  test('revoked tree keeps pending repair and remote object intact', () async {
    await prefs.setScopedFolder(treeA, 'Vault A');
    await prefs.setS3Config(
      const S3Config(
        endpoint: kDefaultS3Endpoint,
        region: kDefaultS3Region,
        bucket: kDefaultS3Bucket,
        accessKeyId: 'test',
        secretAccessKey: 'secret',
      ),
    );
    await session.setPreferredMode(StorageMode.both);
    final id = (await active.createNote(
      'remote',
      now: DateTime(2026, 9, 28, 12),
    )).entry.id;
    await prefs.setDualWritePendingFolders({
      'saf:$treeA': (uploads: [id], deletes: <String>[]),
    });
    grants.remove(treeA);
    await active.replayDualWriteRepairs();
    expect(utf8.decode(s3.objects[id]!), 'remote');
    expect((await prefs.dualWritePendingFolders())['saf:$treeA']?.uploads, [
      id,
    ]);
  });

  test(
    'a repair queued for one tree does not replay from another tree',
    () async {
      await prefs.setScopedFolder(treeA, 'Vault A');
      await prefs.setS3Config(
        const S3Config(
          endpoint: kDefaultS3Endpoint,
          region: kDefaultS3Region,
          bucket: kDefaultS3Bucket,
          accessKeyId: 'test',
          secretAccessKey: 'secret',
        ),
      );
      await session.setPreferredMode(StorageMode.both);
      final id = (await active.createNote(
        'A',
        now: DateTime(2026, 9, 28, 9),
      )).entry.id;
      final pending = await prefs.dualWritePendingFolders();
      expect(pending.keys, isEmpty);
      // Force a pending upload in tree A, then switch to tree B with the same id.
      await prefs.setDualWritePendingFolders({
        'saf:$treeA': (uploads: [id], deletes: <String>[]),
      });
      trees[treeB]![id] = 'B';
      await prefs.setScopedFolder(treeB, 'Vault B');
      await active.replayDualWriteRepairs();
      expect(utf8.decode(s3.objects[id]!), 'A');
      expect((await prefs.dualWritePendingFolders())['saf:$treeA']?.uploads, [
        id,
      ]);
    },
  );

  test(
    'settings export omits the URI and import requires a new selection',
    () async {
      await prefs.setScopedFolder(treeA, 'Private vault');
      final backup = SettingsBackupService(
        preferences: prefs,
        session: session,
      );
      final text = await backup.exportJson();
      expect(text, isNot(contains(treeA)));
      expect(text, isNot(contains('Private vault')));
      expect(
        decodeSettingsBackup(text).settings.scopedFolderNeedsSelection,
        isTrue,
      );
      await backup.importJson(text);
      expect(await prefs.scopedFolder(), isNull);
      expect(await prefs.localStoreKey(), await prefs.directory());
    },
  );
}
