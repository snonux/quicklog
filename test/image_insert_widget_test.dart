import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:quicklog/screens/entry_edit_screen.dart';
import 'package:quicklog/screens/home_screen.dart';
import 'package:quicklog/services/active_note_store.dart';
import 'package:quicklog/services/entry_handle.dart';
import 'package:quicklog/services/image_attachments.dart';
import 'package:quicklog/services/log_service.dart';
import 'package:quicklog/services/preferences.dart';
import 'package:quicklog/services/s3_session_controller.dart';
import 'package:quicklog/widgets/image_insert_buttons.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'io_pump.dart';

/// End-to-end through the UI: pick (faked) → save via the real
/// [ActiveNoteStore] into a temp directory → link in the editor → Log text
/// writes a note that embeds it.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final jpeg = Uint8List.fromList([0xff, 0xd8, 0xff, 0xe0, 9, 9]);

  late String tmp;
  late S3SessionController session;
  late ActiveNoteStore active;
  late List<ImageSource> picked;

  Future<PickedImage?> fakePick(ImageSource source) async {
    picked.add(source);
    return (name: 'IMG_0001.JPG', bytes: jpeg);
  }

  Future<void> setUpStore(WidgetTester tester) async {
    tmp = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('ql-img-ui-'),
    ))!.path;
    SharedPreferences.setMockInitialValues(<String, Object>{
      'flutter.Directory': tmp,
    });
    final prefs = PreferencesService();
    session = S3SessionController(preferences: prefs);
    await session.load();
    active = ActiveNoteStore(preferences: prefs, session: session);
    picked = [];
    addTearDown(() async {
      session.dispose();
      await tester.runAsync(() => Directory(tmp).delete(recursive: true));
    });
  }

  Future<List<String>> files(WidgetTester tester) async =>
      (await tester.runAsync(
        () => Directory(tmp).list().map((e) => p.basename(e.path)).toList(),
      ))!..sort();

  String fieldText(WidgetTester tester) =>
      tester.widget<TextField>(find.byType(TextField)).controller!.text;

  testWidgets('home: camera photo is saved and linked, then logged', (
    tester,
  ) async {
    await setUpStore(tester);
    await tester.pumpWidget(
      MaterialApp(
        home: HomeScreen(
          session: session,
          activeStore: active,
          pickImage: fakePick,
          cameraSupported: true,
        ),
      ),
    );
    await pumpWithIo(tester);

    await tester.enterText(find.byType(TextField), 'Whiteboard');
    await tester.tap(find.byTooltip('Add image'));
    await tester.pumpAndSettle();
    expect(find.text('Choose from gallery'), findsOneWidget);
    await tester.tap(find.text('Take a photo'));
    await pumpWithIo(tester);

    expect(picked, [ImageSource.camera]);
    final images = (await files(tester)).where(isImageAttachmentId).toList();
    expect(images, hasLength(1));
    expect(images.single, endsWith('.jpg'));
    expect(
      await tester.runAsync(
        () => File(p.join(tmp, images.single)).readAsBytes(),
      ),
      jpeg,
    );
    expect(fieldText(tester), 'Whiteboard\n![](${images.single})\n');

    await tester.tap(find.widgetWithText(FilledButton, 'Log text'));
    await pumpWithIo(tester);

    final notes = await tester.runAsync(() => LocalNoteStore(tmp).list());
    expect(notes, hasLength(1));
    expect(
      await tester.runAsync(() => LocalNoteStore(tmp).read(notes!.single.id)),
      'Whiteboard\n![](${images.single})\n',
    );
  });

  testWidgets('home action row does not overflow with the image button', (
    tester,
  ) async {
    await setUpStore(tester);
    tester.view.devicePixelRatio = 1;
    // The test font is far wider than Roboto: at this width its buttons
    // alone fill the row, so the counter has to yield.
    tester.view.physicalSize = const Size(400, 640);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: HomeScreen(
          session: session,
          activeStore: active,
          pickImage: fakePick,
          cameraSupported: true,
        ),
      ),
    );
    await pumpWithIo(tester);
    await tester.enterText(find.byType(TextField), 'x' * 4999);
    await tester.pump();
    // A RenderFlex overflow would have been reported as an exception.
    expect(tester.takeException(), isNull);
  });

  testWidgets('home: gallery pick, and cancelling inserts nothing', (
    tester,
  ) async {
    await setUpStore(tester);
    var cancel = true;
    await tester.pumpWidget(
      MaterialApp(
        home: HomeScreen(
          session: session,
          activeStore: active,
          pickImage: (source) async => cancel ? null : fakePick(source),
          cameraSupported: true,
        ),
      ),
    );
    await pumpWithIo(tester);

    await tester.tap(find.byTooltip('Add image'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Choose from gallery'));
    await pumpWithIo(tester);
    expect(fieldText(tester), isEmpty);
    expect(await files(tester), isEmpty);

    cancel = false;
    await tester.tap(find.byTooltip('Add image'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Choose from gallery'));
    await pumpWithIo(tester);
    expect(picked, [ImageSource.gallery]);
    expect(fieldText(tester), startsWith('![](ql-img-'));
  });

  testWidgets('without a camera the button opens the gallery directly', (
    tester,
  ) async {
    await setUpStore(tester);
    await tester.pumpWidget(
      MaterialApp(
        home: HomeScreen(
          session: session,
          activeStore: active,
          pickImage: fakePick,
          cameraSupported: false,
        ),
      ),
    );
    await pumpWithIo(tester);

    await tester.tap(find.byTooltip('Add image'));
    await pumpWithIo(tester);
    expect(find.text('Take a photo'), findsNothing);
    expect(picked, [ImageSource.gallery]);
    expect(fieldText(tester), startsWith('![](ql-img-'));
  });

  testWidgets('a failed save shows an error and inserts no link', (
    tester,
  ) async {
    await setUpStore(tester);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ImageInsertButtons(
            controller: TextEditingController(text: 'x'),
            saveImage: (_, _) async => throw Exception('disk full'),
            pickImage: fakePick,
            cameraSupported: false,
          ),
        ),
      ),
    );
    await tester.tap(find.byTooltip('Add image'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Could not add the image'), findsOneWidget);
  });

  testWidgets('edit screen: an added image makes the note dirty', (
    tester,
  ) async {
    await setUpStore(tester);
    final store = LocalNoteStore(tmp);
    final entry = (await tester.runAsync(
      () => store.create('existing', now: DateTime(2026, 10, 8, 9)),
    ))!;
    await tester.pumpWidget(
      MaterialApp(
        home: EntryEditScreen(
          handle: _Handle(store, entry),
          saveImage: active.saveImage,
          pickImage: fakePick,
          cameraSupported: true,
        ),
      ),
    );
    await pumpWithIo(tester);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'Save'))
          .enabled,
      isFalse,
    );

    tester.widget<TextField>(find.byType(TextField)).controller!.selection =
        const TextSelection.collapsed(offset: 8);
    await tester.tap(find.byTooltip('Add image'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Take a photo'));
    await pumpWithIo(tester);

    expect(
      fieldText(tester),
      matches(RegExp(r'^existing\n!\[\]\(ql-img-.*\.jpg\)\n$')),
    );
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'Save'))
          .enabled,
      isTrue,
    );
  });

  testWidgets('edit screen without a saver hides the button', (tester) async {
    await setUpStore(tester);
    final store = LocalNoteStore(tmp);
    final entry = (await tester.runAsync(
      () => store.create('existing', now: DateTime(2026, 10, 8, 9)),
    ))!;
    await tester.pumpWidget(
      MaterialApp(home: EntryEditScreen(handle: _Handle(store, entry))),
    );
    await pumpWithIo(tester);
    expect(find.byTooltip('Add image'), findsNothing);
  });
}

class _Handle implements EntryHandle {
  _Handle(this._store, this.entry);

  final NoteStore _store;

  @override
  final LogEntry entry;

  @override
  String get id => entry.id;

  @override
  Future<void> delete() => _store.delete(id);

  @override
  Future<String> firstLine() => _store.firstLine(id);

  @override
  Future<String> preview({int maxChars = 200}) =>
      _store.preview(id, maxChars: maxChars);

  @override
  Future<String> read() => _store.read(id);

  @override
  Future<void> update(String text) => _store.update(id, text);
}
