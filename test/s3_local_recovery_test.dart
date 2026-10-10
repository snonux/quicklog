import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:quicklog/screens/entry_browser_controller.dart';
import 'package:quicklog/services/active_note_store.dart';
import 'package:quicklog/services/browser_note_sources.dart';
import 'package:quicklog/services/dual_write_s3_repair.dart';
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

/// A notes folder that reports every delete together with the text it
/// removed, and can run a hook between a read and its return.
class _SpyStore implements NoteStore {
  _SpyStore(this._inner);

  final NoteStore _inner;
  Future<void> Function(String id)? afterRead;
  Future<void> Function(String id, String text)? onDelete;
  Object? listError;

  @override
  Future<String> read(String id) async {
    final text = await _inner.read(id);
    await afterRead?.call(id);
    return text;
  }

  @override
  Future<void> delete(String id) async {
    await onDelete?.call(id, await _inner.read(id));
    await _inner.delete(id);
  }

  @override
  Future<List<LogEntry>> list() async {
    final error = listError;
    if (error != null) throw error;
    return _inner.list();
  }

  @override
  Future<LogEntry> create(String text, {DateTime? now}) =>
      _inner.create(text, now: now);

  @override
  Future<void> update(String id, String text) => _inner.update(id, text);

  @override
  Future<String> firstLine(String id) => _inner.firstLine(id);

  @override
  Future<String> preview(String id, {int maxChars = 200}) =>
      _inner.preview(id, maxChars: maxChars);
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

  /// Rebuilds [active] over [spy], reached like an Android picker folder.
  Future<void> useSpiedFolder(_SpyStore spy) async {
    final prefs = PreferencesService();
    await prefs.setScopedFolder('content://notes/tree/A', 'A');
    active = ActiveNoteStore(
      preferences: prefs,
      session: session,
      s3ClientFactory: (_) => remote,
      safStoreFactory: (_) => spy,
    );
  }

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
      // Confirmed in the bucket, so the device copy was moved, not kept.
      expect(await local.list(), isEmpty);
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
          expect(utf8.decode(remote.objects[entry.id]!), 'edited');
          // The edit reached the bucket, so its device copy was moved.
          expect(await local.list(), isEmpty);
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
      expect(utf8.decode(remote.objects[entry.id]!), 'latest acknowledged');
      // Confirmed in the bucket, so the device copy was moved, not kept.
      expect(await local.list(), isEmpty);
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
      expect(utf8.decode(remote.objects[idA]!), 'latest A during degrade');
      expect(utf8.decode(remote.objects[idB]!), 'busy B');
      // Both notes are confirmed in the bucket, so both were moved.
      expect(await local.list(), isEmpty);
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
      // Confirmed in the bucket, so the device copy was moved, not kept.
      expect(await local.list(), isEmpty);
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
      // Confirmed in the bucket, so the device copy was moved, not kept.
      expect(await local.list(), isEmpty);
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
        // Uploaded, but its folder was no longer the one in use when the
        // upload was confirmed, so the device copy was left where it was.
        expect(await local.read(fallback.entry.id), 'busy acknowledged');
        await remote.putText(fallback.entry.id, 'newer remote edit');
        await active.replayS3OnlyLocalNotes();
        expect(
          utf8.decode(remote.objects[fallback.entry.id]!),
          'newer remote edit',
        );
        expect(await local.read(fallback.entry.id), 'busy acknowledged');
      },
    );
  }

  test(
    'successful Retry moves every fallback into the bucket',
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
      expect(utf8.decode(remote.objects[second.entry.id]!), 'second');
      // Confirmed in the bucket, so the device copy was moved, not kept.
      expect(await local.list(), isEmpty);
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
      // Confirmed in the bucket, so the device copy was moved, not kept.
      expect(await local.list(), isEmpty);
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

  test('a successful new save moves the local backlog into the bucket', () async {
    final backlog = [
      for (var day = 1; day <= 3; day++)
        await local.create('backlog $day', now: DateTime(2026, 9, day)),
    ];

    final saved = await active.createNote('new', now: DateTime(2026, 9, 4));
    expect(saved.outcome, NoteCreateOutcome.saved);
    // The save does not wait for the backlog; this joins the pass it started.
    await active.replayS3OnlyLocalNotes();

    expect({
      for (final key in remote.objects.keys)
        key: utf8.decode(remote.objects[key]!),
    }, {
      for (final entry in backlog)
        entry.id: 'backlog ${entry.timestamp.day}',
      saved.entry.id: 'new',
    });
    expect(await local.list(), isEmpty);
  });

  test('a note edited on the device while its upload ran is kept', () async {
    final entry = await local.create('uploaded', now: DateTime(2026, 9, 1));
    remote.afterPut = () => local.update(entry.id, 'edited meanwhile');

    await active.replayS3OnlyLocalNotes();

    expect(utf8.decode(remote.objects[entry.id]!), 'uploaded');
    // The device now holds text the bucket does not: never delete that.
    expect(await local.read(entry.id), 'edited meanwhile');
  });

  test(
    'a same-second save landing while the copy is being dropped is not deleted',
    () async {
      final spy = _SpyStore(local);
      await useSpiedFolder(spy);
      final stamp = DateTime(2026, 9, 1);
      final entry = await local.create('uploaded', now: stamp);
      // Whatever is deleted from the device must be what the bucket holds.
      final unsafeDeletes = <String>[];
      spy.onDelete = (id, text) async {
        final inBucket = remote.objects[id];
        if (inBucket == null || utf8.decode(inBucket) != text) {
          unsafeDeletes.add(text);
        }
      };
      // Once the upload has landed, the next read is the drop's own check.
      // Let a new note with the same name be saved right behind that read.
      NoteCreateResult? late;
      remote.afterPut = () async {
        remote.afterPut = null;
        spy.afterRead = (id) async {
          spy.afterRead = null;
          late = await active.createNote('saved meanwhile', now: stamp);
        };
      };

      await active.replayS3OnlyLocalNotes();
      await active.replayS3OnlyLocalNotes();

      expect(late?.outcome, NoteCreateOutcome.savedLocalOnly);
      expect(unsafeDeletes, isEmpty);
      expect(utf8.decode(remote.objects[entry.id]!), 'saved meanwhile');
    },
  );

  test('a copy the bucket already matches is dropped without a PUT', () async {
    final same = await local.create('same', now: DateTime(2026, 9, 1));
    await remote.putText(same.id, 'same');
    remote.puts = 0;

    await active.replayS3OnlyLocalNotes();

    expect(remote.puts, 0);
    expect(utf8.decode(remote.objects[same.id]!), 'same');
    expect(await local.list(), isEmpty);
  });

  test('a kept conflicting copy is dropped once the bucket matches it', () async {
    final kept = await local.create('device', now: DateTime(2026, 9, 1));
    await remote.putText(kept.id, 'other device');
    await active.replayS3OnlyLocalNotes();
    expect(await local.read(kept.id), 'device');

    // Acknowledged copies alone cause no traffic, so nothing changes yet.
    await remote.putText(kept.id, 'device');
    remote.calls = 0;
    await active.replayS3OnlyLocalNotes();
    expect(remote.calls, 0);
    expect(await local.read(kept.id), 'device');

    // The next pass that has work to do also clears the matching leftover.
    final backlog = await local.create('backlog', now: DateTime(2026, 9, 2));
    await active.replayS3OnlyLocalNotes();
    expect(utf8.decode(remote.objects[backlog.id]!), 'backlog');
    expect(await local.list(), isEmpty);
  });

  test('a device copy that cannot be deleted is left as a duplicate', () async {
    final spy = _SpyStore(local);
    await useSpiedFolder(spy);
    final entry = await local.create('stuck', now: DateTime(2026, 9, 1));
    spy.onDelete = (_, _) async => throw const FileSystemException('denied');
    var announced = 0;
    active.localNotesMoved.addListener(() => announced++);

    // The pass neither fails nor reports a move that did not happen.
    await active.replayS3OnlyLocalNotes();
    expect(utf8.decode(remote.objects[entry.id]!), 'stuck');
    expect(await local.read(entry.id), 'stuck');
    expect(announced, 0);

    // Once deleting works, the next pass with a note to move clears it too.
    spy.onDelete = null;
    await local.create('backlog', now: DateTime(2026, 9, 2));
    await active.replayS3OnlyLocalNotes();
    expect(await local.list(), isEmpty);
    expect(announced, 1);
  });

  test('one pass that moves several notes announces it once', () async {
    for (var day = 1; day <= 3; day++) {
      await local.create('note $day', now: DateTime(2026, 9, day));
    }
    var announced = 0;
    active.localNotesMoved.addListener(() => announced++);

    await active.replayS3OnlyLocalNotes();
    expect(await local.list(), isEmpty);
    expect(announced, 1);

    // A pass that only finds a conflicting copy moves and announces nothing.
    final kept = await local.create('device', now: DateTime(2026, 9, 4));
    await remote.putText(kept.id, 'other device');
    await active.replayS3OnlyLocalNotes();
    expect(await local.read(kept.id), 'device');
    expect(announced, 1);
  });

  for (final sameText in [true, false]) {
    test(
      'a key that appears after the listing ${sameText ? "with the same text drops" : "with other text keeps"} the device copy',
      () async {
        final entry = await local.create('device', now: DateTime(2026, 9, 1));
        final arrived = sameText ? 'device' : 'other device';
        remote.afterList = () async {
          remote.afterList = null;
          await remote.putText(entry.id, arrived);
          remote.puts = 0;
        };

        await active.replayS3OnlyLocalNotes();

        // Never overwritten, whichever text got there first.
        expect(remote.puts, 0);
        expect(utf8.decode(remote.objects[entry.id]!), arrived);
        if (sameText) {
          expect(await local.list(), isEmpty);
        } else {
          expect(await local.read(entry.id), 'device');
        }
      },
    );
  }

  test('a failing clean-up read ends the clean-up and marks nothing', () async {
    final copies = [
      for (var day = 1; day <= 3; day++)
        await local.create('same $day', now: DateTime(2026, 9, day)),
    ];
    for (final copy in copies) {
      await remote.putText(copy.id, 'same ${copy.timestamp.day}');
    }
    var reads = 0;
    remote.beforeGet = (_) async {
      reads++;
      throw StateError('connection reset');
    };

    await active.replayS3OnlyLocalNotes();

    // One timeout, not one per copy, and no outage window over tidying up.
    expect(reads, 1);
    expect(session.isDegraded, isFalse);
    expect(await local.list(), hasLength(3));

    // Nothing was acknowledged over a read that never answered, so the
    // next pass comes back to all three without any new note to move.
    remote.beforeGet = null;
    await active.replayS3OnlyLocalNotes();
    expect(await local.list(), isEmpty);
  });

  test('a copy whose clean-up read failed is not parked for good', () async {
    final only = await local.create('same', now: DateTime(2026, 9, 1));
    await remote.putText(only.id, 'same');
    remote.beforeGet = (_) async => throw StateError('connection reset');
    await active.replayS3OnlyLocalNotes();
    expect(await local.read(only.id), 'same');

    // It is the only local note, so nothing else would bring a pass back
    // to it: it must still count as unfinished.
    remote.beforeGet = null;
    await active.replayS3OnlyLocalNotes();
    expect(await local.list(), isEmpty);
  });

  test('an error page the client cannot parse is not a bucket answer', () async {
    // What the S3 client throws when a proxy answers instead of the bucket.
    final copies = [
      for (var day = 1; day <= 2; day++)
        await local.create('same $day', now: DateTime(2026, 9, day)),
    ];
    for (final copy in copies) {
      await remote.putText(copy.id, 'same ${copy.timestamp.day}');
    }
    var reads = 0;
    remote.beforeGet = (_) async {
      reads++;
      throw const FormatException('Bad Gateway');
    };
    await active.replayS3OnlyLocalNotes();
    expect(reads, 1);
    expect(await local.list(), hasLength(2));

    // Nothing was acknowledged, so the next pass still has both to settle.
    remote.beforeGet = null;
    await active.replayS3OnlyLocalNotes();
    expect(await local.list(), isEmpty);
  });

  test('an unreadable copy does not stop the clean-up of the others', () async {
    final corrupt = await local.create('corrupt', now: DateTime(2026, 9, 2));
    await File('${directory.path}/${corrupt.id}').writeAsBytes([0xff]);
    await remote.putText(corrupt.id, 'corrupt');
    final same = await local.create('same', now: DateTime(2026, 9, 1));
    await remote.putText(same.id, 'same');

    await active.replayS3OnlyLocalNotes();

    expect((await local.list()).map((entry) => entry.id), [corrupt.id]);
    expect(
      await File('${directory.path}/${corrupt.id}').readAsBytes(),
      [0xff],
    );
  });

  test('a bucket change during the pass keeps the device copies', () async {
    final notes = [
      for (var day = 1; day <= 2; day++)
        await local.create('note $day', now: DateTime(2026, 9, day)),
    ];
    // The user corrects the bucket while the pass is still uploading to the
    // one it started with.
    remote.afterPut = () async {
      remote.afterPut = null;
      await PreferencesService().setS3Config(
        S3Config.fromRaw(
          bucket: 'corrected',
          accessKeyId: 'test',
          secretAccessKey: 'test',
        ),
      );
    };

    await active.replayS3OnlyLocalNotes();

    // Nothing left the device for a bucket that is no longer the target.
    expect(
      (await local.list()).map((entry) => entry.id),
      unorderedEquals(notes.map((entry) => entry.id)),
    );
    // The corrected bucket (the same fake) then gets them and they move.
    await active.replayS3OnlyLocalNotes();
    expect(await local.list(), isEmpty);
  });

  test(
    'a busy save is not deleted after the bucket changed before its upload',
    () async {
      final corrected = _SelectiveFailureClient();
      final prefs = PreferencesService();
      active = ActiveNoteStore(
        preferences: prefs,
        session: session,
        s3ClientFactory: (config) =>
            config.bucket == 'corrected' ? corrected : remote,
      );
      final entered = Completer<void>();
      final release = Completer<void>();
      remote.beforePut = (_) async {
        remote.beforePut = null;
        entered.complete();
        await release.future;
      };
      final blocker = active.createNote('blocker', now: DateTime(2026, 9, 1));
      await entered.future;
      final busy = await active.createNote('busy', now: DateTime(2026, 9, 2));
      expect(busy.outcome, NoteCreateOutcome.savedLocalOnly);
      await prefs.setS3Config(
        S3Config.fromRaw(
          bucket: 'corrected',
          accessKeyId: 'test',
          secretAccessKey: 'test',
        ),
      );
      release.complete();
      await blocker;

      await active.replayS3OnlyLocalNotes();
      await active.replayS3OnlyLocalNotes();

      // The busy save was reconciled into the bucket it was made for. Had
      // its device copy been deleted then, the corrected bucket would never
      // have received the note.
      expect(utf8.decode(remote.objects[busy.entry.id]!), 'busy');
      expect(utf8.decode(corrected.objects[busy.entry.id]!), 'busy');
    },
  );

  test('a folder change during the pass keeps the device copies', () async {
    final other = await Directory.systemTemp.createTemp('ql-other-folder-');
    addTearDown(() => other.delete(recursive: true));
    final entry = await local.create('note', now: DateTime(2026, 9, 1));
    remote.afterPut = () async {
      remote.afterPut = null;
      await PreferencesService().setDirectory(other.path);
    };

    await active.replayS3OnlyLocalNotes();

    expect(utf8.decode(remote.objects[entry.id]!), 'note');
    expect(await local.read(entry.id), 'note');
  });

  test(
    'a mode change stored by the app stops the background engine from deleting',
    () async {
      // The retry worker is a second engine: its session was loaded once and
      // still says S3 only after the open app has stored another mode.
      final workerSession = S3SessionController(
        preferences: PreferencesService(),
      );
      await workerSession.load();
      addTearDown(workerSession.dispose);
      final worker = ActiveNoteStore(
        preferences: PreferencesService(),
        session: workerSession,
        s3ClientFactory: (_) => remote,
      );
      final entry = await local.create('note', now: DateTime(2026, 9, 1));
      remote.afterPut = () async {
        remote.afterPut = null;
        await PreferencesService().setStorageMode(StorageMode.both);
      };

      await worker.replayS3OnlyLocalNotes();

      expect(workerSession.preferredMode, StorageMode.s3);
      expect(utf8.decode(remote.objects[entry.id]!), 'note');
      expect(await local.read(entry.id), 'note');
    },
  );

  test('a settings change during the last read before the delete counts', () async {
    final spy = _SpyStore(local);
    await useSpiedFolder(spy);
    final entry = await local.create('note', now: DateTime(2026, 9, 1));
    // Once the upload has landed, the next read is the drop's own check.
    remote.afterPut = () async {
      remote.afterPut = null;
      spy.afterRead = (_) async {
        spy.afterRead = null;
        await PreferencesService().setStorageMode(StorageMode.both);
      };
    };

    await active.replayS3OnlyLocalNotes();

    expect(utf8.decode(remote.objects[entry.id]!), 'note');
    expect(await local.read(entry.id), 'note');
  });

  test('a matching copy with replacement characters is kept as well', () async {
    final entry = await local.create('caf�', now: DateTime(2026, 9, 1));
    await remote.putText(entry.id, 'caf�');

    await active.replayS3OnlyLocalNotes();

    expect(await local.read(entry.id), 'caf�');
  });

  test('a bucket object that is not text does not end the clean-up', () async {
    final binary = await local.create('binary', now: DateTime(2026, 9, 2));
    await remote.putObject(binary.id, [0xff]);
    final same = await local.create('same', now: DateTime(2026, 9, 1));
    await remote.putText(same.id, 'same');

    await active.replayS3OnlyLocalNotes();

    expect((await local.list()).map((entry) => entry.id), [binary.id]);
    expect(remote.objects[binary.id], [0xff]);
    expect(session.isDegraded, isFalse);
  });

  test('a first move of many notes re-lists before it has finished', () async {
    for (var minute = 0; minute < 30; minute++) {
      await local.create('note', now: DateTime(2026, 9, 1, 0, minute));
    }
    final leftWhenAnnounced = <int>[];
    active.localNotesMoved.addListener(() {
      leftWhenAnnounced.add(directory.listSync().length);
    });

    await active.replayS3OnlyLocalNotes();

    // Once after 25 notes, once at the end: not per note, not only at the end.
    expect(leftWhenAnnounced, [5, 0]);
  });

  test('a note with replacement characters is uploaded but kept', () async {
    // What a document-provider folder returns for a file with invalid
    // bytes: the device file may hold more than the uploaded text.
    final entry = await local.create(
      'caf�',
      now: DateTime(2026, 9, 1),
    );

    await active.replayS3OnlyLocalNotes();

    expect(utf8.decode(remote.objects[entry.id]!), 'caf�');
    expect(await local.read(entry.id), 'caf�');
  });

  test('a note with an upload repair queued meanwhile is kept', () async {
    final entry = await local.create('uploaded', now: DateTime(2026, 9, 1));
    // Another engine records newer device text for this note right after
    // the upload landed (the text itself is written a moment later).
    remote.afterPut = () async {
      remote.afterPut = null;
      await DualWriteS3Repair(
        preferences: PreferencesService(),
      ).enqueueUpload(entry.id, folderKey: directory.path);
    };

    await active.replayS3OnlyLocalNotes();
    expect(await local.read(entry.id), 'uploaded');

    // The next pass replays that repair, clears it and only then moves.
    await active.replayS3OnlyLocalNotes();
    expect(utf8.decode(remote.objects[entry.id]!), 'uploaded');
    expect(await local.list(), isEmpty);
    expect(await PreferencesService().dualWritePendingUploads(), isEmpty);
  });

  group('browser rows that outlived a move', () {
    late LogEntry entry;
    late BrowserNoteSources sources;

    LocatedLogEntry row(NoteStorageLocation location) =>
        LocatedLogEntry(entry: entry, location: location);

    setUp(() async {
      entry = await local.create('moved', now: DateTime(2026, 9, 1));
      sources = await active.resolveBrowserSources();
      await active.replayS3OnlyLocalNotes();
      expect(await local.list(), isEmpty);
    });

    for (final location in [
      NoteStorageLocation.local,
      NoteStorageLocation.both,
    ]) {
      test('editing a stale ${location.name} row does not bring the file back',
          () async {
        await sources.update(row(location), 'edited');
        expect(utf8.decode(remote.objects[entry.id]!), 'edited');
        expect(await local.list(), isEmpty);
      });

      test('deleting a stale ${location.name} row deletes the bucket note',
          () async {
        await sources.delete(row(location));
        expect(remote.objects, isEmpty);
        expect(await local.list(), isEmpty);
      });
    }

    test('Move to S3 on a stale local row is already done', () async {
      remote.puts = 0;
      await sources.uploadLocalToS3(row(NoteStorageLocation.local));
      expect(remote.puts, 0);
      expect(utf8.decode(remote.objects[entry.id]!), 'moved');
    });

    test('Move to S3 does not claim success while the bucket is unreachable',
        () async {
      remote.alwaysFail = StateError('offline');
      await expectLater(
        sources.uploadLocalToS3(row(NoteStorageLocation.local)),
        throwsA(isA<FileSystemException>()),
      );
    });

    test('an unlistable notes folder does not pass for a moved file', () async {
      // The note is in the bucket, but whether the device still has it
      // cannot be told: that must not be reported as a finished move.
      await directory.delete(recursive: true);
      addTearDown(() => directory.create());
      await expectLater(
        sources.uploadLocalToS3(row(NoteStorageLocation.local)),
        throwsA(isA<FileSystemException>()),
      );
    });

    test('editing a row over an unlistable folder still tries the device',
        () async {
      // Whether the device copy is gone cannot be told, so the row keeps
      // counting as being in both places: the bucket gets the edit and the
      // device error is reported, not skipped.
      await directory.delete(recursive: true);
      addTearDown(() => directory.create());
      await expectLater(
        sources.update(row(NoteStorageLocation.both), 'edited'),
        throwsA(isA<FileSystemException>()),
      );
      expect(utf8.decode(remote.objects[entry.id]!), 'edited');
    });

    test('Move to S3 still fails for a note that is nowhere', () async {
      remote.objects.clear();
      await expectLater(
        sources.uploadLocalToS3(row(NoteStorageLocation.local)),
        throwsA(isA<FileSystemException>()),
      );
      expect(remote.objects, isEmpty);
    });
  });

  test('a picker folder that cannot be listed keeps its rows as they are',
      () async {
    final spy = _SpyStore(local);
    await useSpiedFolder(spy);
    final entry = await local.create('device', now: DateTime(2026, 9, 1));
    await remote.putText(entry.id, 'bucket');
    final sources = await active.resolveBrowserSources();
    spy.listError = StateError('document provider unavailable');

    await sources.update(
      LocatedLogEntry(entry: entry, location: NoteStorageLocation.both),
      'edited',
    );

    // Not mistaken for a moved file: both sides received the edit.
    expect(utf8.decode(remote.objects[entry.id]!), 'edited');
    expect(await local.read(entry.id), 'edited');
  });

  test('the entry browser re-lists after a pass moved notes', () async {
    final entry = await local.create('backlog', now: DateTime(2026, 9, 1));
    final browser = EntryBrowserController(
      session: session,
      activeStore: active,
      preferences: PreferencesService(),
    );
    addTearDown(browser.dispose);
    browser.start();
    expect((await browser.future)!.single.location, NoteStorageLocation.local);
    final listed = browser.future;

    await active.replayS3OnlyLocalNotes();

    expect(browser.future, isNot(same(listed)));
    final rows = (await browser.future)!;
    expect(rows.single.id, entry.id);
    expect(rows.single.location, NoteStorageLocation.s3);
  });

  test(
    'recovery uploads missing notes and preserves newer remote content',
    () async {
      final missing = await local.create('missing', now: DateTime(2026, 9, 1));
      final present = await local.create('stale', now: DateTime(2026, 9, 2));
      await remote.putText(present.id, 'newer remote');
      await active.replayS3OnlyLocalNotes();
      final rows = await active.listForBrowser();
      // The uploaded note was moved. The conflicting one is in both places:
      // the bucket's text wins there and the device keeps its own.
      expect({for (final row in rows) row.id: row.location}, {
        missing.id: NoteStorageLocation.s3,
        present.id: NoteStorageLocation.both,
      });
      expect(utf8.decode(remote.objects[missing.id]!), 'missing');
      expect(utf8.decode(remote.objects[present.id]!), 'newer remote');
      expect(await local.read(present.id), 'stale');
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
      // Only the note that reached the bucket left the device.
      expect(await local.read(bad.id), 'rejected');
      expect(
        (await local.list()).map((entry) => entry.id),
        unorderedEquals([bad.id, corrupt.id]),
      );
      remote.failedKey = null;
      await active.replayS3OnlyLocalNotes();
      expect(utf8.decode(remote.objects[bad.id]!), 'rejected');
      expect((await local.list()).map((entry) => entry.id), [corrupt.id]);
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
      // The bucket now holds other text: the device copy is not redundant.
      expect(await local.read(entry.id), 'safe');
    },
  );

  test(
    'lost upload response: the next pass finds the note in the bucket and moves it',
    () async {
      final entry = await local.create('safe', now: DateTime(2026, 9, 1));
      remote.putSucceedsButThrows = StateError('response lost');
      await active.replayS3OnlyLocalNotes();
      // Unconfirmed, so nothing was deleted, although the PUT did land.
      expect(await local.read(entry.id), 'safe');
      expect(utf8.decode(remote.objects[entry.id]!), 'safe');
      remote.puts = 0;

      await active.replayS3OnlyLocalNotes();

      expect(remote.puts, 0);
      expect(utf8.decode(remote.objects[entry.id]!), 'safe');
      expect(await local.list(), isEmpty);
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
