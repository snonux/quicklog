import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:quicklog/screens/entry_browser_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'io_pump.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late File entryFile;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('ql-browser-');
    entryFile = File(p.join(tmp.path, 'ql-260507-143045.md'));
    await entryFile.writeAsString('note body');
    SharedPreferences.setMockInitialValues(<String, Object>{
      'flutter.Directory': tmp.path,
    });
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  Future<void> pumpBrowser(WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: EntryBrowserScreen()));
    await pumpWithIo(tester);
  }

  testWidgets('lists entries with a visible delete action', (tester) async {
    await pumpBrowser(tester);

    expect(find.text('2026-05-07 14:30:45'), findsOneWidget);
    expect(find.byIcon(Icons.delete_outline), findsOneWidget);
  });

  testWidgets('delete icon opens the confirmation screen and cancelling keeps '
      'the entry', (tester) async {
    await pumpBrowser(tester);

    await tester.tap(find.byIcon(Icons.delete_outline));
    await pumpWithIo(tester);
    expect(find.text('Delete entry?'), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await pumpWithIo(tester);

    expect(await fileExists(tester, entryFile), isTrue);
    expect(find.text('2026-05-07 14:30:45'), findsOneWidget);
  });

  testWidgets('confirming removes the file and the list row', (tester) async {
    await pumpBrowser(tester);

    await tester.tap(find.byIcon(Icons.delete_outline));
    await pumpWithIo(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await pumpWithIo(tester);

    expect(await fileExists(tester, entryFile), isFalse);
    expect(find.text('2026-05-07 14:30:45'), findsNothing);
    expect(find.textContaining('Deleted ql-260507-143045.md'), findsOneWidget);
  });

  testWidgets('long-press still opens the confirmation screen', (tester) async {
    await pumpBrowser(tester);

    await tester.longPress(find.text('2026-05-07 14:30:45'));
    await pumpWithIo(tester);

    expect(find.text('Delete entry?'), findsOneWidget);
  });

  testWidgets('the row edit icon opens the editor and saving updates the list',
      (tester) async {
    await pumpBrowser(tester);

    await tester.tap(find.byIcon(Icons.edit_outlined));
    await pumpWithIo(tester);
    expect(find.text('note body'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'edited body');
    await pumpWithIo(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await pumpWithIo(tester);
    await tester.pump(const Duration(seconds: 1));

    final content = await tester.runAsync(() => entryFile.readAsString());
    expect(content, 'edited body');
    // Back on the list, whose subtitle is re-read from the changed file.
    expect(find.text('Entries'), findsOneWidget);
    expect(find.text('edited body'), findsOneWidget);
  });

  testWidgets('editing from the detail view shows the new text',
      (tester) async {
    await pumpBrowser(tester);

    await tester.tap(find.text('2026-05-07 14:30:45'));
    await pumpWithIo(tester);
    await tester.tap(find.byIcon(Icons.edit_outlined));
    await pumpWithIo(tester);

    await tester.enterText(find.byType(TextField), 'detail edit');
    await pumpWithIo(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await pumpWithIo(tester);
    await tester.pump(const Duration(seconds: 1));

    // Still on the detail screen (its app bar shows the filename), with the
    // re-read content.
    expect(find.text('ql-260507-143045.md'), findsOneWidget);
    expect(find.text('detail edit'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
  });

  testWidgets('deleting from the detail view returns to the list',
      (tester) async {
    await pumpBrowser(tester);

    await tester.tap(find.text('2026-05-07 14:30:45'));
    await pumpWithIo(tester);
    expect(find.text('note body'), findsOneWidget);

    // The app bar action of the detail screen, then confirm.
    await tester.tap(find.byIcon(Icons.delete_outline));
    await pumpWithIo(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await pumpWithIo(tester);

    expect(await fileExists(tester, entryFile), isFalse);
    expect(find.text('Entries'), findsOneWidget);
    expect(find.text('2026-05-07 14:30:45'), findsNothing);
  });
}
