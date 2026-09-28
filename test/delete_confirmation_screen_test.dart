import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:quicklog/screens/delete_confirmation_screen.dart';
import 'package:quicklog/services/entry_handle.dart';
import 'package:quicklog/services/log_service.dart';
import 'package:quicklog/services/s3_note_store.dart';

import 'io_pump.dart';
import 'support/memory_s3_object_client.dart';

class _CountingS3 extends MemoryS3ObjectClient {
  final Map<String, int> gets = {};

  @override
  Future<List<int>> getObject(String key) {
    gets.update(key, (count) => count + 1, ifAbsent: () => 1);
    return super.getObject(key);
  }
}

/// Pumps a button that opens the confirmation screen for [entry] and records
/// the boolean it returns, mirroring how the entry browser uses it.
Future<List<bool>> _pumpConfirmFlow(
  WidgetTester tester,
  EntryHandle handle,
) async {
  final answers = <bool>[];
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => TextButton(
            onPressed: () async =>
                answers.add(await confirmEntryDeletion(ctx, handle)),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await pumpWithIo(tester);
  return answers;
}

void main() {
  late Directory tmp;
  late LocalNoteStore store;
  late LogEntry entry;
  late File entryFile;
  const id = 'ql-260507-143045.md';

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('ql-delete-');
    store = LocalNoteStore(tmp.path);
    entryFile = File(p.join(tmp.path, id));
    await entryFile.writeAsString('first line\nsecond line');
    entry = LogEntry(id: id, timestamp: DateTime(2026, 5, 7, 14, 30, 45));
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  testWidgets('shows filename, timestamp and a preview of the content', (
    tester,
  ) async {
    await _pumpConfirmFlow(tester, BoundNoteStore(store, entry));

    expect(find.text('Delete entry?'), findsOneWidget);
    expect(find.text(id), findsOneWidget);
    expect(find.text('2026-05-07 14:30:45'), findsOneWidget);
    expect(find.text('first line\nsecond line'), findsOneWidget);
  });

  testWidgets('rebuilds keep the same S3 preview read', (tester) async {
    final s3 = _CountingS3();
    await s3.putText(id, 'remote preview');
    final handle = BoundNoteStore(S3NoteStore(s3), entry);

    for (var i = 0; i < 4; i++) {
      await tester.pumpWidget(
        MaterialApp(home: DeleteConfirmationScreen(handle: handle)),
      );
      await tester.pump();
    }

    expect(find.text('remote preview'), findsOneWidget);
    expect(s3.gets, {id: 1});
  });

  testWidgets('changing the handle reads and shows the new S3 preview', (
    tester,
  ) async {
    const otherId = 'ql-260508-143045.md';
    final otherEntry = LogEntry(
      id: otherId,
      timestamp: DateTime(2026, 5, 8, 14, 30, 45),
    );
    final s3 = _CountingS3();
    await s3.putText(id, 'first preview');
    await s3.putText(otherId, 'second preview');
    final s3Store = S3NoteStore(s3);
    final firstHandle = BoundNoteStore(s3Store, entry);
    final secondHandle = BoundNoteStore(s3Store, otherEntry);

    Future<void> show(EntryHandle handle) async {
      await tester.pumpWidget(
        MaterialApp(home: DeleteConfirmationScreen(handle: handle)),
      );
      await tester.pump();
    }

    await show(firstHandle);
    await show(firstHandle);
    expect(find.text('first preview'), findsOneWidget);
    expect(s3.gets, {id: 1});

    await show(secondHandle);
    await show(secondHandle);
    expect(find.text(otherId), findsOneWidget);
    expect(find.text('second preview'), findsOneWidget);
    expect(find.text('first preview'), findsNothing);
    expect(s3.gets, {id: 1, otherId: 1});
  });

  testWidgets('failed S3 preview shows an error and still permits deletion', (
    tester,
  ) async {
    final s3 = _CountingS3()..alwaysFail = Exception('read failed');
    final answers = await _pumpConfirmFlow(
      tester,
      BoundNoteStore(S3NoteStore(s3), entry),
    );

    expect(find.textContaining('Could not read file:'), findsOneWidget);
    expect(find.textContaining('read failed'), findsOneWidget);
    expect(s3.gets, {id: 1});

    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await pumpWithIo(tester);

    expect(answers, [true]);
  });

  testWidgets('Cancel returns false and leaves the file on disk', (
    tester,
  ) async {
    final answers = await _pumpConfirmFlow(
      tester,
      BoundNoteStore(store, entry),
    );

    await tester.tap(find.text('Cancel'));
    await pumpWithIo(tester);

    expect(answers, [false]);
    expect(await fileExists(tester, entryFile), isTrue);
  });

  testWidgets('Delete returns true but does not delete by itself', (
    tester,
  ) async {
    final answers = await _pumpConfirmFlow(
      tester,
      BoundNoteStore(store, entry),
    );

    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await pumpWithIo(tester);

    expect(answers, [true]);
    // The screen only asks; the caller performs the deletion.
    expect(await fileExists(tester, entryFile), isTrue);
  });

  testWidgets('dismissing the screen without choosing returns false', (
    tester,
  ) async {
    final answers = await _pumpConfirmFlow(
      tester,
      BoundNoteStore(store, entry),
    );

    await tester.pageBack();
    await pumpWithIo(tester);

    expect(answers, [false]);
    expect(await fileExists(tester, entryFile), isTrue);
  });
}
