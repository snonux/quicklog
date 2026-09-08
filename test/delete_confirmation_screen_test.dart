import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:quicklog/screens/delete_confirmation_screen.dart';
import 'package:quicklog/services/log_service.dart';

import 'io_pump.dart';

/// Pumps a button that opens the confirmation screen for [entry] and records
/// the boolean it returns, mirroring how the entry browser uses it.
Future<List<bool>> _pumpConfirmFlow(
  WidgetTester tester,
  NoteStore store,
  LogEntry entry,
) async {
  final answers = <bool>[];
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => TextButton(
            onPressed: () async =>
                answers.add(await confirmEntryDeletion(ctx, store, entry)),
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

  testWidgets('shows filename, timestamp and a preview of the content',
      (tester) async {
    await _pumpConfirmFlow(tester, store, entry);

    expect(find.text('Delete entry?'), findsOneWidget);
    expect(find.text(id), findsOneWidget);
    expect(find.text('2026-05-07 14:30:45'), findsOneWidget);
    expect(find.text('first line\nsecond line'), findsOneWidget);
  });

  testWidgets('Cancel returns false and leaves the file on disk',
      (tester) async {
    final answers = await _pumpConfirmFlow(tester, store, entry);

    await tester.tap(find.text('Cancel'));
    await pumpWithIo(tester);

    expect(answers, [false]);
    expect(await fileExists(tester, entryFile), isTrue);
  });

  testWidgets('Delete returns true but does not delete by itself',
      (tester) async {
    final answers = await _pumpConfirmFlow(tester, store, entry);

    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await pumpWithIo(tester);

    expect(answers, [true]);
    // The screen only asks; the caller performs the deletion.
    expect(await fileExists(tester, entryFile), isTrue);
  });

  testWidgets('dismissing the screen without choosing returns false',
      (tester) async {
    final answers = await _pumpConfirmFlow(tester, store, entry);

    await tester.pageBack();
    await pumpWithIo(tester);

    expect(answers, [false]);
    expect(await fileExists(tester, entryFile), isTrue);
  });
}
