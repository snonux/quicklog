import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:quicklog/screens/entry_edit_screen.dart';
import 'package:quicklog/services/entry_handle.dart';
import 'package:quicklog/services/log_service.dart';

import 'io_pump.dart';

/// Writes through [inner], then throws. Models a dual-write that landed on
/// one backend and failed on the other.
class _WriteThenThrow implements EntryHandle {
  _WriteThenThrow(this._inner, this.entry);

  final NoteStore _inner;

  @override
  final LogEntry entry;

  @override
  String get id => entry.id;

  @override
  Future<void> delete() => _inner.delete(id);

  @override
  Future<String> firstLine() => _inner.firstLine(id);

  @override
  Future<String> preview({int maxChars = 200}) =>
      _inner.preview(id, maxChars: maxChars);

  @override
  Future<String> read() => _inner.read(id);

  @override
  Future<void> update(String text) async {
    await _inner.update(id, text);
    throw Exception('write landed, then failed');
  }
}

/// Holds [EntryHandle.update] until [release], so a test can press back while
/// the save is still in flight. [error] is thrown instead of writing.
class _HeldUpdate implements EntryHandle {
  _HeldUpdate(this._inner, this.entry);

  final NoteStore _inner;
  final Completer<void> _gate = Completer<void>();
  Object? _error;

  @override
  final LogEntry entry;

  @override
  String get id => entry.id;

  void release({Object? error}) {
    _error = error;
    if (!_gate.isCompleted) _gate.complete();
  }

  @override
  Future<void> delete() => _inner.delete(id);

  @override
  Future<String> firstLine() => _inner.firstLine(id);

  @override
  Future<String> preview({int maxChars = 200}) =>
      _inner.preview(id, maxChars: maxChars);

  @override
  Future<String> read() => _inner.read(id);

  @override
  Future<void> update(String text) async {
    await _gate.future;
    final error = _error;
    if (error != null) throw error;
    await _inner.update(id, text);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late LocalNoteStore store;
  late LogEntry entry;
  const id = 'ql-260507-143045.md';

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('ql-edit-');
    store = LocalNoteStore(tmp.path);
    await File(p.join(tmp.path, id)).writeAsString('original body');
    entry = LogEntry(
      id: id,
      timestamp: DateTime(2026, 5, 7, 14, 30, 45),
    );
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  /// Pumps a host screen whose button opens the editor, so the editor sits on
  /// a pushed route: that is what the app does, and it is the only way to
  /// exercise back navigation and the pop result.
  Future<List<bool?>> pumpEditor(
    WidgetTester tester, {
    EntryHandle? handle,
  }) async {
    final opened = handle ?? BoundNoteStore(store, entry);
    final results = <bool?>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => TextButton(
              onPressed: () async => results.add(await editEntry(ctx, opened)),
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
    return await tester.runAsync(() => store.read(id)) ?? '';
  }

  testWidgets('loads the file content with save and revert disabled',
      (tester) async {
    await pumpEditor(tester);

    expect(find.text(id), findsOneWidget);
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
    expect(results, <bool?>[true]);
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
    expect(results, <bool?>[false]);
  });

  testWidgets('revert after a failed update is not a clean back',
      (tester) async {
    final results = await pumpEditor(
      tester,
      handle: _WriteThenThrow(store, entry),
    );

    await tester.enterText(find.byType(TextField), 'partial body');
    await pumpWithIo(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await pumpWithIo(tester);
    expect(find.textContaining('Could not save'), findsOneWidget);

    // The error snack sits on the action row.
    await tester.pump(const Duration(seconds: 4));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.widgetWithText(OutlinedButton, 'Revert'));
    await pumpWithIo(tester);
    expect(find.text('original body'), findsOneWidget);

    await tester.pageBack();
    await pumpAfterPop(tester);

    expect(find.text('Discard changes?'), findsNothing);
    expect(find.byType(TextField), findsNothing);
    expect(results, <bool?>[false]);
    // Revert restores the field, not the file the failed update already wrote.
    expect(await readEntry(tester), 'partial body');
  });

  /// Starts a save, puts the field back to the loaded text, and presses back
  /// while [held] is still blocking [NoteStore.update].
  Future<void> saveThenBackWithOriginalText(
    WidgetTester tester,
    _HeldUpdate held,
  ) async {
    await tester.enterText(find.byType(TextField), 'edited body');
    await pumpWithIo(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pump();

    await tester.enterText(find.byType(TextField), 'original body');
    await tester.pump();
    await tester.pageBack();
    // Long enough for a route exit to finish, so a pop is not hidden by the
    // transition still being on screen.
    await tester.pump(const Duration(seconds: 1));

    expect(find.byType(TextField), findsOneWidget);
    expect(find.text('Discard changes?'), findsNothing);
    expect(find.text('original body'), findsOneWidget);
    expect(held._gate.isCompleted, isFalse);
  }

  testWidgets('back during an in-flight save waits, then pops true once',
      (tester) async {
    final held = _HeldUpdate(store, entry);
    final results = await pumpEditor(tester, handle: held);
    await saveThenBackWithOriginalText(tester, held);
    expect(results, isEmpty);

    held.release();
    await pumpAfterPop(tester);

    expect(results, <bool?>[true]);
    expect(find.byType(TextField), findsNothing);
    expect(find.text('open'), findsOneWidget);
    expect(await readEntry(tester), 'edited body');
  });

  testWidgets('a save that fails after back stays on the editor',
      (tester) async {
    final held = _HeldUpdate(store, entry);
    final results = await pumpEditor(tester, handle: held);
    await saveThenBackWithOriginalText(tester, held);

    held.release(error: Exception('still writing'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(find.textContaining('Could not save'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
    expect(find.text('Discard changes?'), findsNothing);
    expect(results, isEmpty);
    expect(find.text('open'), findsNothing);
    expect(await readEntry(tester), 'original body');
  });

  testWidgets('leaving an untouched entry does not ask', (tester) async {
    final results = await pumpEditor(tester);

    await tester.pageBack();
    await pumpAfterPop(tester);

    expect(find.text('Discard changes?'), findsNothing);
    expect(find.byType(TextField), findsNothing);
    expect(results, <bool?>[null]);
  });

  testWidgets('an unreadable entry shows the error instead of an empty editor',
      (tester) async {
    await tester.runAsync(() => File(p.join(tmp.path, id)).delete());

    await pumpEditor(tester);

    expect(find.textContaining('Could not read file:'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
  });
}
