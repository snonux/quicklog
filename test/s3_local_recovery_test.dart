import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:quicklog/services/active_note_store.dart';
import 'package:quicklog/services/log_service.dart';
import 'package:quicklog/services/merged_note_listing.dart';
import 'package:quicklog/services/preferences.dart';
import 'package:quicklog/services/s3_session_controller.dart';
import 'package:quicklog/services/s3_config.dart';
import 'package:quicklog/services/s3_object_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/memory_s3_object_client.dart';

class _SelectiveFailureClient extends MemoryS3ObjectClient {
  String? failedKey;
  Future<void> Function()? afterPut;
  Future<void> Function()? afterList;
  Future<void> Function(String key)? beforeGet;
  Future<void> Function(String key)? beforePut;
  int lists = 0;
  int puts = 0;

  @override
  Future<List<String>> listKeys({String prefix = ''}) async {
    lists++;
    final keys = await super.listKeys(prefix: prefix);
    await afterList?.call();
    return keys;
  }

  @override
  Future<List<int>> getObject(String key) async {
    await beforeGet?.call(key);
    return super.getObject(key);
  }

  @override
  Future<void> putObject(
    String key,
    List<int> bytes, {
    String contentType = 'text/markdown',
  }) async {
    puts++;
    await beforePut?.call(key);
    if (key == failedKey) throw StateError('upload rejected');
    await super.putObject(key, bytes, contentType: contentType);
    await afterPut?.call();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late LocalNoteStore local;
  late _SelectiveFailureClient remote;
  late S3SessionController session;
  late ActiveNoteStore active;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('ql-recovery-');
    local = LocalNoteStore(directory.path);
    SharedPreferences.setMockInitialValues({
      'flutter.Directory': directory.path,
      'flutter.StorageMode': 's3',
      'flutter.S3AccessKeyId': 'test',
      'flutter.S3SecretAccessKey': 'test',
    });
    final prefs = PreferencesService();
    session = S3SessionController(preferences: prefs);
    await session.load();
    remote = _SelectiveFailureClient();
    active = ActiveNoteStore(
      preferences: prefs,
      session: session,
      s3ClientFactory: (config) {
        final error = MinioS3ObjectClient.configError(config);
        if (error != null) throw S3ConfigException(error);
        return remote;
      },
    );
    active.bindSessionProbe();
  });

  tearDown(() async {
    session.dispose();
    await directory.delete(recursive: true);
  });

  test('startup finishes while recovery LIST is stalled', () async {
    await local.create('backlog', now: DateTime(2026, 9, 1));
    final prefs = PreferencesService();
    await prefs.setDegradedUntil(
      DateTime.now().subtract(const Duration(minutes: 1)),
    );
    final coldSession = S3SessionController(preferences: prefs);
    addTearDown(coldSession.dispose);
    final coldActive = ActiveNoteStore(
      preferences: prefs,
      session: coldSession,
      s3ClientFactory: (_) => remote,
    );
    coldActive.bindSessionProbe();
    final entered = Completer<void>();
    final release = Completer<void>();
    remote.afterList = () async {
      entered.complete();
      await release.future;
    };
    try {
      await coldSession
          .load(waitForRecovery: false)
          .timeout(const Duration(seconds: 2));
      await entered.future;
      expect(coldSession.loaded, isTrue);
      expect(remote.objects, isEmpty);
    } finally {
      release.complete();
    }
    await coldActive.replayS3OnlyLocalNotes();
  });

  for (final stalledOperation in ['LIST', 'PUT']) {
    test(
      'saved new note finishes while recovery $stalledOperation is stalled',
      () async {
        final backlog = await local.create(
          'backlog',
          now: DateTime(2026, 9, 1),
        );
        final entered = Completer<void>();
        final release = Completer<void>();
        if (stalledOperation == 'LIST') {
          remote.afterList = () async {
            entered.complete();
            await release.future;
          };
        } else {
          remote.beforePut = (key) async {
            if (key == backlog.id) {
              entered.complete();
              await release.future;
            }
          };
        }
        final save = active.createNote('new', now: DateTime(2026, 9, 2));
        try {
          await entered.future;
          final result = await save.timeout(const Duration(seconds: 2));
          expect(result.outcome, NoteCreateOutcome.saved);
          expect(utf8.decode(remote.objects[result.entry.id]!), 'new');
          expect(remote.objects.containsKey(backlog.id), isFalse);
        } finally {
          release.complete();
        }
        await active.replayS3OnlyLocalNotes();
        expect(utf8.decode(remote.objects[backlog.id]!), 'backlog');
      },
    );
  }

  test(
    'new save during a stalled recovery PUT falls back locally immediately',
    () async {
      final backlog = await local.create('backlog', now: DateTime(2026, 9, 1));
      final entered = Completer<void>();
      final release = Completer<void>();
      remote.beforePut = (key) async {
        if (key == backlog.id) {
          entered.complete();
          await release.future;
        }
      };
      final replay = active.replayS3OnlyLocalNotes();
      await entered.future;
      try {
        final result = await active
            .createNote('foreground', now: DateTime(2026, 9, 2))
            .timeout(const Duration(seconds: 2));
        expect(result.outcome, NoteCreateOutcome.savedLocalOnly);
        expect(await local.read(result.entry.id), 'foreground');
        expect(remote.objects.containsKey(result.entry.id), isFalse);
        expect(session.isDegraded, isFalse);
      } finally {
        release.complete();
      }
      await replay;
      await active.replayS3OnlyLocalNotes();
      expect(utf8.decode(remote.objects['ql-260902-000000.md']!), 'foreground');
    },
  );

  test('recovery uploads notes only and leaves v0.4.0 images alone', () async {
    final backlog = await local.create('backlog', now: DateTime(2026, 9, 1));
    // Pictures v0.4.0 kept on the device while S3 was down, plus look-alikes:
    // a zero-byte one, a type it never wrote, and one ending in `.md`.
    final images = <String, List<int>>{
      'ql-img-260901-000000-123.jpg': [0xFF, 0xD8, 0xFF],
      'ql-img-260901-000000-124.png': const [],
      'ql-img-260901-000000-125.bmp': [0x42, 0x4D],
      'ql-img-260901-000000-126.md': utf8.encode('not a note'),
    };
    for (final image in images.entries) {
      await File('${directory.path}/${image.key}').writeAsBytes(image.value);
    }

    await active.replayS3OnlyLocalNotes();

    expect(remote.objects.keys, [backlog.id]);
    expect(remote.puts, 1);
    for (final image in images.entries) {
      final file = File('${directory.path}/${image.key}');
      expect(await file.exists(), isTrue, reason: image.key);
      expect(await file.readAsBytes(), image.value, reason: image.key);
    }
  });

  test('manual Retry waits for backlog PUT completion', () async {
    final backlog = await local.create('backlog', now: DateTime(2026, 9, 1));
    final entered = Completer<void>();
    final release = Completer<void>();
    remote.beforePut = (key) async {
      if (key == backlog.id) {
        entered.complete();
        await release.future;
      }
    };
    var finished = false;
    final retry = session.retryS3().then((result) {
      finished = true;
      return result;
    });
    try {
      await entered.future;
      expect(finished, isFalse);
    } finally {
      release.complete();
    }
    expect(await retry, S3RetryResult.reachable);
    expect(utf8.decode(remote.objects[backlog.id]!), 'backlog');
  });

  test('overlapping recovery triggers share a single upload pass', () async {
    await local.create('backlog', now: DateTime(2026, 9, 1));
    final entered = Completer<void>();
    final release = Completer<void>();
    remote.afterList = () async {
      entered.complete();
      await release.future;
    };
    final first = active.replayS3OnlyLocalNotes();
    await entered.future;
    final second = active.replayS3OnlyLocalNotes();
    expect(identical(first, second), isTrue);
    release.complete();
    await Future.wait([first, second]);
    expect(remote.lists, 1);
    expect(remote.puts, 1);
  });

  test(
    'fresh read preserves an object inserted after the LIST snapshot',
    () async {
      final entry = await local.create('stale', now: DateTime(2026, 9, 1));
      remote.afterList = () async {
        remote.objects[entry.id] = utf8.encode('remote new');
      };
      await active.replayS3OnlyLocalNotes();
      expect(utf8.decode(remote.objects[entry.id]!), 'remote new');
      expect(remote.puts, 0);
    },
  );

  test(
    'in-app save during recovery check wins over stale local content',
    () async {
      final stamp = DateTime(2026, 9, 1);
      final entry = await local.create('stale local', now: stamp);
      final entered = Completer<void>();
      final release = Completer<void>();
      remote.beforeGet = (key) async {
        if (key == entry.id) {
          entered.complete();
          await release.future;
        }
      };
      final replay = active.replayS3OnlyLocalNotes();
      await entered.future;
      final save = active.createNote('new save', now: stamp);
      try {
        expect(
          (await save.timeout(const Duration(seconds: 2))).outcome,
          NoteCreateOutcome.savedLocalOnly,
        );
      } finally {
        release.complete();
      }
      await replay;
      remote.beforeGet = null;
      await active.replayS3OnlyLocalNotes();
      expect(utf8.decode(remote.objects[entry.id]!), 'new save');
      expect(await local.read(entry.id), 'new save');
    },
  );

  for (final mutation in ['edit', 'delete']) {
    test(
      'browser $mutation waits for stalled recovery PUT and reconciles stale row',
      () async {
        final entry = await local.create('old', now: DateTime(2026, 9, 1));
        final sources = await active.resolveBrowserSources();
        final row = LocatedLogEntry(
          entry: entry,
          location: NoteStorageLocation.local,
        );
        final entered = Completer<void>();
        final release = Completer<void>();
        var firstPut = true;
        remote.beforePut = (key) async {
          if (firstPut) {
            firstPut = false;
            entered.complete();
            await release.future;
          }
        };
        final replay = active.replayS3OnlyLocalNotes();
        await entered.future;
        final changed = mutation == 'edit'
            ? sources.update(row, 'edited')
            : sources.delete(row);
        expect(await local.read(entry.id), 'old');
        release.complete();
        await replay;
        await changed;
        await active.replayS3OnlyLocalNotes();
        if (mutation == 'edit') {
          expect(await local.read(entry.id), 'edited');
          expect(utf8.decode(remote.objects[entry.id]!), 'edited');
        } else {
          expect(await local.list(), isEmpty);
          expect(remote.objects, isEmpty);
        }
      },
    );
  }

  test(
    'new create remains local-safe while a browser edit PUT is stalled',
    () async {
      final entry = await local.create('old', now: DateTime(2026, 9, 1));
      await remote.putText(entry.id, 'old');
      final sources = await active.resolveBrowserSources();
      final row = LocatedLogEntry(
        entry: entry,
        location: NoteStorageLocation.both,
      );
      final entered = Completer<void>();
      final release = Completer<void>();
      remote.beforePut = (_) async {
        entered.complete();
        await release.future;
      };
      final edit = sources.update(row, 'edited');
      await entered.future;
      try {
        final saved = await active
            .createNote('new', now: DateTime(2026, 9, 2))
            .timeout(const Duration(seconds: 2));
        expect(saved.outcome, NoteCreateOutcome.savedLocalOnly);
        expect(await local.read(saved.entry.id), 'new');
        expect(remote.objects.containsKey(saved.entry.id), isFalse);
      } finally {
        release.complete();
      }
      await edit;
      expect(await local.read(entry.id), 'edited');
    },
  );

  test(
    'same-id create during stalled recovery PUT reconciles newest local text',
    () async {
      final stamp = DateTime(2026, 9, 1);
      final entry = await local.create('old', now: stamp);
      final entered = Completer<void>();
      final release = Completer<void>();
      var firstPut = true;
      remote.beforePut = (key) async {
        if (firstPut) {
          firstPut = false;
          entered.complete();
          await release.future;
        }
      };
      final replay = active.replayS3OnlyLocalNotes();
      await entered.future;
      try {
        final saved = await active
            .createNote('latest', now: stamp)
            .timeout(const Duration(seconds: 2));
        expect(saved.outcome, NoteCreateOutcome.savedLocalOnly);
        expect(await local.read(entry.id), 'latest');
      } finally {
        release.complete();
      }
      await replay;
      expect(utf8.decode(remote.objects[entry.id]!), 'latest');
      expect(remote.puts, 2);
    },
  );

  test('mode change during fresh remote GET prevents recovery PUT', () async {
    final entry = await local.create('safe local', now: DateTime(2026, 9, 1));
    remote.beforeGet = (_) => session.setPreferredMode(StorageMode.local);
    await active.replayS3OnlyLocalNotes();
    expect(remote.puts, 0);
    expect(await local.read(entry.id), 'safe local');
  });

  for (final blocker in ['foreground create', 'browser edit']) {
    test('same-id busy fallback supersedes a stalled $blocker PUT', () async {
      final stamp = DateTime(2026, 9, 1);
      final entry = await local.create('original', now: stamp);
      final sources = await active.resolveBrowserSources();
      if (blocker == 'browser edit') await remote.putText(entry.id, 'original');
      final entered = Completer<void>();
      final release = Completer<void>();
      var firstPut = true;
      remote.beforePut = (_) async {
        if (firstPut) {
          firstPut = false;
          entered.complete();
          await release.future;
        }
      };
      final blocked = blocker == 'foreground create'
          ? active.createNote('older create', now: stamp)
          : sources.update(
              LocatedLogEntry(entry: entry, location: NoteStorageLocation.both),
              'older edit',
            );
      await entered.future;
      try {
        final latest = await active
            .createNote('latest acknowledged', now: stamp)
            .timeout(const Duration(seconds: 2));
        expect(latest.outcome, NoteCreateOutcome.savedLocalOnly);
        expect(await local.read(entry.id), 'latest acknowledged');
      } finally {
        release.complete();
      }
      await blocked;
      await active.replayS3OnlyLocalNotes();
      expect(await local.read(entry.id), 'latest acknowledged');
      expect(utf8.decode(remote.objects[entry.id]!), 'latest acknowledged');
    });
  }

  test(
    'failed busy-fallback repair survives a fresh ActiveNoteStore',
    () async {
      final stamp = DateTime(2026, 9, 1);
      final entered = Completer<void>();
      final release = Completer<void>();
      var firstPut = true;
      remote.beforePut = (_) async {
        if (firstPut) {
          firstPut = false;
          entered.complete();
          await release.future;
        }
      };
      final older = active.createNote('older', now: stamp);
      await entered.future;
      final latest = await active.createNote('latest durable', now: stamp);
      remote.afterPut = () async {
        remote.failedKey = latest.entry.id;
      };
      release.complete();
      await older;
      await active.replayS3OnlyLocalNotes();
      expect(await local.read(latest.entry.id), 'latest durable');
      expect(utf8.decode(remote.objects[latest.entry.id]!), 'older');
      final prefs = PreferencesService();
      expect(await prefs.dualWritePendingUploads(), contains(latest.entry.id));
      remote.failedKey = null;
      remote.afterPut = null;
      final fresh = ActiveNoteStore(
        preferences: prefs,
        session: session,
        s3ClientFactory: (_) => remote,
      );
      await fresh.replayS3OnlyLocalNotes();
      expect(utf8.decode(remote.objects[latest.entry.id]!), 'latest durable');
      expect(await prefs.dualWritePendingUploads(), isEmpty);
    },
  );

  test(
    'later browser delete wins over an earlier busy fallback repair',
    () async {
      final stamp = DateTime(2026, 9, 1);
      final entry = await local.create('original', now: stamp);
      final sources = await active.resolveBrowserSources();
      final entered = Completer<void>();
      final release = Completer<void>();
      var firstPut = true;
      remote.beforePut = (_) async {
        if (firstPut) {
          firstPut = false;
          entered.complete();
          await release.future;
        }
      };
      final older = active.createNote('older', now: stamp);
      await entered.future;
      await active.createNote('latest', now: stamp);
      final deleted = sources.delete(
        LocatedLogEntry(entry: entry, location: NoteStorageLocation.local),
      );
      release.complete();
      await older;
      await deleted;
      await active.replayS3OnlyLocalNotes();
      expect(await local.list(), isEmpty);
      expect(remote.objects, isEmpty);
      expect(await PreferencesService().dualWritePendingUploads(), isEmpty);
    },
  );

  test(
    'stalled persisted repair does not block a new durable fallback',
    () async {
      final existing = await local.create('pending', now: DateTime(2026, 9, 1));
      final prefs = PreferencesService();
      await prefs.setDualWritePendingFolders({
        directory.path: (uploads: [existing.id], deletes: <String>[]),
      });
      final entered = Completer<void>();
      final release = Completer<void>();
      var firstPut = true;
      remote.beforePut = (_) async {
        if (firstPut) {
          firstPut = false;
          entered.complete();
          await release.future;
        }
      };
      final replay = active.replayS3OnlyLocalNotes();
      await entered.future;
      try {
        final saved = await active
            .createNote('new durable', now: DateTime(2026, 9, 2))
            .timeout(const Duration(seconds: 2));
        expect(saved.outcome, NoteCreateOutcome.savedLocalOnly);
        expect(await local.read(saved.entry.id), 'new durable');
        expect(await prefs.dualWritePendingUploads(), contains(saved.entry.id));
      } finally {
        release.complete();
      }
      await replay;
    },
  );

  test(
    'failed older create and failed repair preserve newer acknowledged fallback',
    () async {
      final stamp = DateTime(2026, 9, 1);
      final id = logEntryIdFor(stamp);
      final entered = Completer<void>();
      final release = Completer<void>();
      var firstPut = true;
      remote.beforePut = (_) async {
        if (firstPut) {
          firstPut = false;
          entered.complete();
          await release.future;
        }
      };
      remote.failedKey = id;
      final older = active.createNote('older failure', now: stamp);
      await entered.future;
      final latest = await active.createNote('latest acknowledged', now: stamp);
      expect(latest.outcome, NoteCreateOutcome.savedLocalOnly);
      release.complete();
      expect((await older).outcome, NoteCreateOutcome.savedLocalOnly);
      expect(await local.read(id), 'latest acknowledged');
      final prefs = PreferencesService();
      expect(await prefs.dualWritePendingUploads(), contains(id));
      remote.failedKey = null;
      final freshSession = S3SessionController(preferences: prefs);
      addTearDown(freshSession.dispose);
      await freshSession.load();
      await freshSession.retryS3(probe: () async {});
      final fresh = ActiveNoteStore(
        preferences: prefs,
        session: freshSession,
        s3ClientFactory: (_) => remote,
      );
      await fresh.replayS3OnlyLocalNotes();
      expect(utf8.decode(remote.objects[id]!), 'latest acknowledged');
    },
  );

  for (final primaryFails in [false, true]) {
    for (final stalledRepair in ['GET', 'PUT']) {
      test(
        'primary ${primaryFails ? "failure" : "success"} completes while another fallback repair $stalledRepair stalls',
        () async {
          final stampA = DateTime(2026, 9, 1);
          final idA = logEntryIdFor(stampA);
          final idB = logEntryIdFor(DateTime(2026, 9, 2));
          final firstEntered = Completer<void>();
          final firstRelease = Completer<void>();
          final repairEntered = Completer<void>();
          final repairRelease = Completer<void>();
          var firstPut = true;
          remote.beforePut = (key) async {
            if (key == idA && firstPut) {
              firstPut = false;
              firstEntered.complete();
              await firstRelease.future;
            }
            if (key == idB && stalledRepair == 'PUT') {
              repairEntered.complete();
              await repairRelease.future;
            }
          };
          remote.beforeGet = (key) async {
            if (key == idB && stalledRepair == 'GET') {
              repairEntered.complete();
              await repairRelease.future;
            }
          };
          final primary = active.createNote('primary A', now: stampA);
          await firstEntered.future;
          final secondary = await active.createNote(
            'busy B',
            now: DateTime(2026, 9, 2),
          );
          expect(secondary.outcome, NoteCreateOutcome.savedLocalOnly);
          if (primaryFails) remote.failedKey = idA;
          firstRelease.complete();
          await repairEntered.future;
          try {
            final result = await primary.timeout(const Duration(seconds: 2));
            expect(
              result.outcome,
              primaryFails
                  ? NoteCreateOutcome.savedLocalOnly
                  : NoteCreateOutcome.saved,
            );
            if (primaryFails) expect(await local.read(idA), 'primary A');
          } finally {
            repairRelease.complete();
          }
          remote.beforeGet = null;
          remote.beforePut = null;
          remote.failedKey = null;
          await session.retryS3(probe: () async {});
          await active.replayS3OnlyLocalNotes();
        },
      );
    }
  }

  test(
    'new degraded-mode same-id ACK supersedes an earlier failed create',
    () async {
      final stampA = DateTime(2026, 9, 1);
      final idA = logEntryIdFor(stampA);
      final stampB = DateTime(2026, 9, 2);
      final idB = logEntryIdFor(stampB);
      final firstEntered = Completer<void>();
      final firstRelease = Completer<void>();
      final repairEntered = Completer<void>();
      final repairRelease = Completer<void>();
      var firstPut = true;
      remote.beforePut = (key) async {
        if (key == idA && firstPut) {
          firstPut = false;
          firstEntered.complete();
          await firstRelease.future;
        }
      };
      remote.beforeGet = (key) async {
        if (key == idB) {
          repairEntered.complete();
          await repairRelease.future;
        }
      };
      final older = active.createNote('older A', now: stampA);
      await firstEntered.future;
      await active.createNote('busy B', now: stampB);
      remote.failedKey = idA;
      firstRelease.complete();
      await repairEntered.future;
      expect(
        (await older.timeout(const Duration(seconds: 2))).outcome,
        NoteCreateOutcome.savedLocalOnly,
      );
      expect(session.isDegraded, isTrue);
      final latest = await active.createNote(
        'latest A during degrade',
        now: stampA,
      );
      expect(latest.outcome, NoteCreateOutcome.savedLocalOnly);
      expect(await local.read(idA), 'latest A during degrade');
      expect(
        await PreferencesService().dualWritePendingUploads(),
        contains(idA),
      );
      remote.failedKey = null;
      repairRelease.complete();
      remote.beforeGet = null;
      await session.retryS3(probe: () async {});
      await active.replayS3OnlyLocalNotes();
      expect(await local.read(idA), 'latest A during degrade');
      expect(utf8.decode(remote.objects[idA]!), 'latest A during degrade');
    },
  );

  for (final restart in [false, true]) {
    test(
      'later direct same-id save retires stale repair ${restart ? "after restart" : "in same instance"}',
      () async {
        final stamp = DateTime(2026, 9, 1);
        final id = logEntryIdFor(stamp);
        final entered = Completer<void>();
        final release = Completer<void>();
        var firstPut = true;
        remote.beforePut = (_) async {
          if (firstPut) {
            firstPut = false;
            entered.complete();
            await release.future;
          }
        };
        final older = active.createNote('initial remote', now: stamp);
        await entered.future;
        await active.createNote('old retained fallback', now: stamp);
        remote.afterPut = () async {
          remote.failedKey = id;
        };
        release.complete();
        await older;
        await active.replayS3OnlyLocalNotes();
        expect(utf8.decode(remote.objects[id]!), 'initial remote');
        final prefs = PreferencesService();
        expect(await prefs.dualWritePendingUploads(), contains(id));
        remote.failedKey = null;
        remote.afterPut = null;
        final writer = restart
            ? ActiveNoteStore(
                preferences: prefs,
                session: session,
                s3ClientFactory: (_) => remote,
              )
            : active;
        final newer = await writer.createNote(
          'new successful save',
          now: stamp,
        );
        expect(newer.outcome, NoteCreateOutcome.saved);
        await writer.replayS3OnlyLocalNotes();
        expect(utf8.decode(remote.objects[id]!), 'new successful save');
        expect(await prefs.dualWritePendingUploads(), isEmpty);
      },
    );
  }

  test(
    'direct same-id success preserves a newer fallback arriving during its PUT',
    () async {
      final stamp = DateTime(2026, 9, 1);
      final entry = await local.create('old queued local', now: stamp);
      final prefs = PreferencesService();
      await prefs.setDualWritePendingFolders({
        directory.path: (uploads: [entry.id], deletes: <String>[]),
      });
      final entered = Completer<void>();
      final release = Completer<void>();
      final repairEntered = Completer<void>();
      final repairRelease = Completer<void>();
      var firstPut = true;
      remote.beforePut = (_) async {
        if (firstPut) {
          firstPut = false;
          entered.complete();
          await release.future;
        }
      };
      remote.beforeGet = (key) async {
        repairEntered.complete();
        await repairRelease.future;
      };
      final direct = active.createNote('direct new', now: stamp);
      await entered.future;
      await active.createNote('latest fallback', now: stamp);
      release.complete();
      await repairEntered.future;
      expect(
        (await direct.timeout(const Duration(seconds: 2))).outcome,
        NoteCreateOutcome.saved,
      );
      expect(await prefs.dualWritePendingUploads(), contains(entry.id));
      repairRelease.complete();
      remote.beforeGet = null;
      await active.replayS3OnlyLocalNotes();
      expect(utf8.decode(remote.objects[entry.id]!), 'latest fallback');
      expect(await local.read(entry.id), 'latest fallback');
      expect(await prefs.dualWritePendingUploads(), isEmpty);
    },
  );

  for (final branch in ['degraded', 'invalid config']) {
    test('newer $branch ACK retires a retained older busy repair', () async {
      final stamp = DateTime(2026, 9, 1);
      final id = logEntryIdFor(stamp);
      final entered = Completer<void>();
      final release = Completer<void>();
      var firstPut = true;
      remote.beforePut = (_) async {
        if (firstPut) {
          firstPut = false;
          entered.complete();
          await release.future;
        }
      };
      final older = active.createNote('initial remote', now: stamp);
      await entered.future;
      await active.createNote('old retained fallback', now: stamp);
      remote.afterPut = () async {
        remote.failedKey = id;
      };
      release.complete();
      await older;
      await active.replayS3OnlyLocalNotes();
      expect(utf8.decode(remote.objects[id]!), 'initial remote');
      final prefs = PreferencesService();
      final originalConfig = await prefs.s3Config();
      if (branch == 'degraded') {
        await session.markS3Failed();
      } else {
        await prefs.setS3Config(
          S3Config(
            endpoint: 'http://',
            region: originalConfig.region,
            bucket: originalConfig.bucket,
            accessKeyId: originalConfig.accessKeyId,
            secretAccessKey: originalConfig.secretAccessKey,
          ),
        );
      }
      final latest = await active.createNote('latest local ACK', now: stamp);
      expect(
        latest.outcome,
        branch == 'degraded'
            ? NoteCreateOutcome.savedLocalOnly
            : NoteCreateOutcome.savedLocalS3SettingsInvalid,
      );
      expect(await local.read(id), 'latest local ACK');
      expect(await prefs.dualWritePendingUploads(), contains(id));
      remote.failedKey = null;
      remote.afterPut = null;
      await prefs.setS3Config(originalConfig);
      await session.retryS3(probe: () async {});
      await active.replayS3OnlyLocalNotes();
      expect(utf8.decode(remote.objects[id]!), 'latest local ACK');
      expect(await local.read(id), 'latest local ACK');
      expect(await prefs.dualWritePendingUploads(), isEmpty);
    });
  }

  for (final scoped in [false, true]) {
    test(
      'busy repair retains original ${scoped ? "SAF" : "directory"} queue scope across folder change',
      () async {
        final otherFolder = await Directory.systemTemp.createTemp(
          'ql-other-scope-',
        );
        addTearDown(() => otherFolder.delete(recursive: true));
        final prefs = PreferencesService();
        const uriA = 'content://notes/tree/A';
        const uriB = 'content://notes/tree/B';
        if (scoped) {
          await prefs.setScopedFolder(uriA, 'A');
          active = ActiveNoteStore(
            preferences: prefs,
            session: session,
            s3ClientFactory: (_) => remote,
            safStoreFactory: (uri) =>
                LocalNoteStore(uri == uriA ? directory.path : otherFolder.path),
          );
        }
        final entered = Completer<void>();
        final release = Completer<void>();
        var firstPut = true;
        remote.beforePut = (_) async {
          if (firstPut) {
            firstPut = false;
            entered.complete();
            await release.future;
          }
        };
        final blocker = active.createNote('blocker', now: DateTime(2026, 9, 1));
        await entered.future;
        final fallback = await active.createNote(
          'busy acknowledged',
          now: DateTime(2026, 9, 2),
        );
        if (scoped) {
          await prefs.setScopedFolder(uriB, 'B');
        } else {
          await prefs.setDirectory(otherFolder.path);
        }
        release.complete();
        await blocker;
        await active.replayS3OnlyLocalNotes();
        final queues = await prefs.dualWritePendingFolders();
        expect(
          queues[scoped ? 'saf:$uriA' : directory.path]?.uploads ?? <String>[],
          isEmpty,
        );
        expect(
          utf8.decode(remote.objects[fallback.entry.id]!),
          'busy acknowledged',
        );
        if (scoped) {
          await prefs.setScopedFolder(uriA, 'A');
        } else {
          await prefs.setDirectory(directory.path);
        }
        await remote.putText(fallback.entry.id, 'newer remote edit');
        await active.replayS3OnlyLocalNotes();
        expect(
          utf8.decode(remote.objects[fallback.entry.id]!),
          'newer remote edit',
        );
      },
    );
  }

  test(
    'successful Retry uploads every fallback and keeps local copies',
    () async {
      remote.alwaysFail = StateError('offline');
      final first = await active.createNote('first', now: DateTime(2026, 9, 1));
      final second = await active.createNote(
        'second',
        now: DateTime(2026, 9, 2),
      );
      expect(first.outcome, NoteCreateOutcome.savedLocalOnly);
      expect(second.outcome, NoteCreateOutcome.savedLocalOnly);
      remote.alwaysFail = null;

      expect(await session.retryS3(), S3RetryResult.reachable);
      expect(
        remote.objects.keys,
        unorderedEquals([first.entry.id, second.entry.id]),
      );
      expect(utf8.decode(remote.objects[first.entry.id]!), 'first');
      expect(await local.read(second.entry.id), 'second');
      expect(session.isDegraded, isFalse);
    },
  );

  test(
    'cold start with expired persisted window uploads fallback notes',
    () async {
      final entry = await local.create(
        'cold fallback',
        now: DateTime(2026, 9, 1),
      );
      final prefs = PreferencesService();
      await prefs.setDegradedUntil(
        DateTime.now().subtract(const Duration(minutes: 1)),
      );
      final coldSession = S3SessionController(preferences: prefs);
      addTearDown(coldSession.dispose);
      final coldActive = ActiveNoteStore(
        preferences: prefs,
        session: coldSession,
        s3ClientFactory: (_) => remote,
      );
      coldActive.bindSessionProbe();
      expect(coldSession.loaded, isFalse);
      await coldSession.load();
      expect(utf8.decode(remote.objects[entry.id]!), 'cold fallback');
      expect(await prefs.degradedUntil(), isNull);
    },
  );

  test(
    'expired degrade window replays local notes when session reloads',
    () async {
      final entry = await local.create(
        'expired fallback',
        now: DateTime(2026, 9, 1),
      );
      final failedAt = DateTime.now();
      await session.markS3Failed(now: failedAt);
      await session.load(now: failedAt.add(kS3DegradeDuration));
      expect(utf8.decode(remote.objects[entry.id]!), 'expired fallback');
      expect(await local.read(entry.id), 'expired fallback');
    },
  );

  test(
    'successful new save uploads backlog without overwriting its own key',
    () async {
      final old = await local.create('stale local', now: DateTime(2026, 9, 1));
      final other = await local.create('backlog', now: DateTime(2026, 9, 2));
      final saved = await active.createNote(
        'new text',
        now: DateTime(2026, 9, 1),
      );
      expect(saved.outcome, NoteCreateOutcome.saved);
      await active.replayS3OnlyLocalNotes();
      expect(utf8.decode(remote.objects[old.id]!), 'new text');
      expect(utf8.decode(remote.objects[other.id]!), 'backlog');
      expect(await local.read(old.id), 'stale local');
    },
  );

  test(
    'recovery uploads missing notes and preserves newer remote content',
    () async {
      final missing = await local.create('missing', now: DateTime(2026, 9, 1));
      final present = await local.create('stale', now: DateTime(2026, 9, 2));
      await remote.putText(present.id, 'newer remote');
      await active.replayS3OnlyLocalNotes();
      final rows = await active.listForBrowser();
      expect(
        rows.map((row) => row.location),
        everyElement(NoteStorageLocation.both),
      );
      expect(utf8.decode(remote.objects[missing.id]!), 'missing');
      expect(utf8.decode(remote.objects[present.id]!), 'newer remote');
    },
  );

  test(
    'one rejected upload and unreadable note do not strand remaining notes',
    () async {
      final bad = await local.create('rejected', now: DateTime(2026, 9, 3));
      final corrupt = await local.create('corrupt', now: DateTime(2026, 9, 2));
      await File('${directory.path}/${corrupt.id}').writeAsBytes([0xff]);
      final good = await local.create('good', now: DateTime(2026, 9, 1));
      remote.failedKey = bad.id;
      await session.markS3Failed();
      expect(await session.retryS3(), S3RetryResult.reachable);
      expect(remote.objects.keys, [good.id]);
      expect(await local.read(bad.id), 'rejected');
      remote.failedKey = null;
      await active.replayS3OnlyLocalNotes();
      expect(utf8.decode(remote.objects[bad.id]!), 'rejected');
    },
  );

  test(
    'lost upload response leaves local safe and next pass skips existing key',
    () async {
      final entry = await local.create('safe', now: DateTime(2026, 9, 1));
      remote.putSucceedsButThrows = StateError('response lost');
      await active.replayS3OnlyLocalNotes();
      expect(await local.read(entry.id), 'safe');
      await remote.putText(entry.id, 'remote edit');
      await active.replayS3OnlyLocalNotes();
      expect(utf8.decode(remote.objects[entry.id]!), 'remote edit');
    },
  );

  test(
    'LIST failure prevents uploads and preserves a successfully saved new note',
    () async {
      await local.create('backlog', now: DateTime(2026, 9, 1));
      remote.afterPut = () async {
        remote.alwaysFail = StateError('LIST unavailable');
      };
      final result = await active.createNote('new', now: DateTime(2026, 9, 2));
      expect(result.outcome, NoteCreateOutcome.saved);
      await active.replayS3OnlyLocalNotes();
      expect(remote.objects.keys, [result.entry.id]);
      expect(await local.list(), hasLength(1));
    },
  );

  test(
    'changing mode during replay stops remaining uploads and keeps files',
    () async {
      final newest = await local.create('newest', now: DateTime(2026, 9, 2));
      final oldest = await local.create('oldest', now: DateTime(2026, 9, 1));
      remote.afterPut = () => session.setPreferredMode(StorageMode.local);
      await active.replayS3OnlyLocalNotes();
      expect(remote.objects.keys, [newest.id]);
      expect(await local.read(newest.id), 'newest');
      expect(await local.read(oldest.id), 'oldest');
    },
  );

  test(
    'empty local folder, local mode and active degrade do not contact S3',
    () async {
      await active.replayS3OnlyLocalNotes();
      expect(remote.calls, 0);
      await local.create('local', now: DateTime(2026, 9, 1));
      await session.setPreferredMode(StorageMode.local);
      await active.replayS3OnlyLocalNotes();
      expect(remote.calls, 0);
      await session.setPreferredMode(StorageMode.s3);
      await session.markS3Failed();
      await active.replayS3OnlyLocalNotes();
      expect(remote.calls, 0);
    },
  );
}
