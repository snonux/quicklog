import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:quicklog/screens/entry_edit_screen.dart';
import 'package:quicklog/services/log_service.dart';

import 'io_pump.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late File entryFile;
  late LogEntry entry;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('ql-edit-');
    entryFile = File(p.join(tmp.path, 'ql-260507-143045.md'));
    await entryFile.writeAsString('original body');
    entry = LogEntry(
      file: entryFile,
      timestamp: DateTime(2026, 5, 7, 14, 30, 45),
    );
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  /// Pumps a host screen whose button opens the editor, so the editor sits on
  /// a pushed route: that is what the app does, and it is the only way to
  /// exercise back navigation and the pop result.
  Future<List<bool>> pumpEditor(WidgetTester tester) async {
    final results = <bool>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => TextButton(
              onPressed: () async => results.add(await editEntry(ctx, entry)),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await pumpWithIo(tester);
    return results;
  }

  /// [pumpWithIo] settles the file reads, but its short interleaved pumps
  /// leave a route exit transition mid-flight; one plain long pump finishes
  /// it, so "the editor is gone" can actually be asserted.
  Future<void> pumpAfterPop(WidgetTester tester) async {
    await pumpWithIo(tester);
    await tester.pump(const Duration(seconds: 1));
  }

  Future<String> readEntry(WidgetTester tester) async {
    return await tester.runAsync(() => entryFile.readAsString()) ?? '';
  }

  testWidgets('loads the file content with save and revert disabled',
      (tester) async {
    await pumpEditor(tester);

    expect(find.text('ql-260507-143045.md'), findsOneWidget);
    expect(find.text('original body'), findsOneWidget);
    expect(find.text('13 chars'), findsOneWidget);
    final save = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Save'),
    );
    expect(save.onPressed, isNull);
    final revert = tester.widget<OutlinedButton>(
      find.widgetWithText(OutlinedButton, 'Revert'),
    );
    expect(revert.onPressed, isNull);
  });

  testWidgets('saving writes the edited text and pops with true',
      (tester) async {
    final results = await pumpEditor(tester);

    await tester.enterText(find.byType(TextField), 'edited body');
    await pumpWithIo(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await pumpAfterPop(tester);

    expect(await readEntry(tester), 'edited body');
    expect(results, <bool>[true]);
    expect(find.byType(TextField), findsNothing);
  });

  testWidgets('revert restores the on-disk text without writing',
      (tester) async {
    await pumpEditor(tester);

    await tester.enterText(find.byType(TextField), 'scratch');
    await pumpWithIo(tester);
    await tester.tap(find.widgetWithText(OutlinedButton, 'Revert'));
    await pumpWithIo(tester);

    expect(find.text('original body'), findsOneWidget);
    expect(await readEntry(tester), 'original body');
  });

  testWidgets('leaving with unsaved changes asks before discarding them',
      (tester) async {
    final results = await pumpEditor(tester);

    await tester.enterText(find.byType(TextField), 'half-typed');
    await pumpWithIo(tester);
    await tester.pageBack();
    await pumpWithIo(tester);
    expect(find.text('Discard changes?'), findsOneWidget);

    // Keeping the editor open must not lose what was typed.
    await tester.tap(find.text('Keep editing'));
    await pumpWithIo(tester);
    expect(find.text('half-typed'), findsOneWidget);

    await tester.pageBack();
    await pumpWithIo(tester);
    await tester.tap(find.text('Discard'));
    await pumpAfterPop(tester);

    expect(find.byType(TextField), findsNothing);
    expect(await readEntry(tester), 'original body');
    expect(results, <bool>[false]);
  });

  testWidgets('leaving an untouched entry does not ask', (tester) async {
    await pumpEditor(tester);

    await tester.pageBack();
    await pumpAfterPop(tester);

    expect(find.text('Discard changes?'), findsNothing);
    expect(find.byType(TextField), findsNothing);
  });

  testWidgets('an unreadable entry shows the error instead of an empty editor',
      (tester) async {
    await tester.runAsync(() => entryFile.delete());

    await pumpEditor(tester);

    expect(find.textContaining('Could not read file:'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
  });
}
