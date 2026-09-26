import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:quicklog/screens/home_screen.dart';
import 'package:quicklog/services/active_note_store.dart';
import 'package:quicklog/services/preferences.dart';
import 'package:quicklog/services/s3_session_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'io_pump.dart';

/// End to end through the real app UI, as a user switching from a debug build
/// to the F-Droid build would do it: set every option in Preferences, export
/// to a file, wipe all app data (uninstall), import, and check that every
/// value is back -- on screen and in storage.
///
/// Runs on the desktop code path (typed file path, real file on disk), which
/// is what `flutter test` on Linux exercises. The Android path differs only in
/// the file dialog, which is the system's.
void main() {
  late Directory tmp;
  late String exportPath;
  late String notesDir;
  late S3SessionController session;
  late ActiveNoteStore active;

  const endpoint = 'http://garage.example.invalid:3900';
  const region = 'home-lab';
  const bucket = 'ql-backup-test';
  const accessKey = 'GKE2E0ACCESSKEY';
  const secret = 'e2e/secret+value=with "quotes"';

  Future<void> freshProcess() async {
    session = S3SessionController();
    await session.load();
    active = ActiveNoteStore(session: session);
    active.bindSessionProbe();
  }

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('ql-settings-e2e-');
    exportPath = p.join(tmp.path, 'backup', 'quicklog-settings.json');
    notesDir = p.join(tmp.path, 'notes');
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await freshProcess();
  });

  tearDown(() async {
    session.dispose();
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  Future<void> pumpApp(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: HomeScreen(session: session, activeStore: active),
      ),
    );
    await pumpWithIo(tester);
  }

  Future<void> openPreferences(WidgetTester tester) async {
    await tester.tap(find.byTooltip('Preferences'));
    await pumpWithIo(tester);
    expect(find.text('Preferences'), findsOneWidget);
  }

  /// A Preferences text field, by the key the screen gives it.
  Finder field(String key) => find.byKey(ValueKey('prefs.$key'));

  /// Brings [finder] on screen in the (lazily built) Preferences list,
  /// whatever the window size: back to the top, then down until it shows.
  Future<void> scrollTo(WidgetTester tester, Finder finder) async {
    final scrollable = find.byType(Scrollable).first;
    tester.state<ScrollableState>(scrollable).position.jumpTo(0);
    await tester.pump();
    await tester.scrollUntilVisible(finder, 200, scrollable: scrollable);
    await tester.pump();
  }

  Future<void> type(WidgetTester tester, String key, String text) async {
    await scrollTo(tester, field(key));
    await tester.enterText(field(key), text);
    await tester.pump();
  }

  Future<String> textOf(WidgetTester tester, String key) async {
    await scrollTo(tester, field(key));
    return tester.widget<TextField>(field(key)).controller!.text;
  }

  final autoLogTile = find.widgetWithText(
    SwitchListTile,
    'Auto-log shared text',
  );
  final modeButton = find.byType(SegmentedButton<StorageMode>);

  Future<bool> autoLogSwitch(WidgetTester tester) async {
    await scrollTo(tester, autoLogTile);
    return tester.widget<SwitchListTile>(autoLogTile).value;
  }

  Future<Set<StorageMode>> selectedMode(WidgetTester tester) async {
    await scrollTo(tester, modeButton);
    return tester.widget<SegmentedButton<StorageMode>>(modeButton).selected;
  }

  Future<void> tapScrolled(WidgetTester tester, Finder finder) async {
    await scrollTo(tester, finder);
    await tester.tap(finder);
    await pumpWithIo(tester);
  }

  Future<void> typePathAndConfirm(
    WidgetTester tester,
    String path,
    String button,
  ) async {
    final field = find.byKey(const ValueKey('settingsPathField'));
    expect(field, findsOneWidget);
    await tester.enterText(field, path);
    await tester.tap(find.widgetWithText(FilledButton, button));
    await pumpWithIo(tester, rounds: 20);
  }

  testWidgets('every option survives export, wipe and import', (tester) async {
    // 1. Set every option through the Preferences UI.
    await pumpApp(tester);
    await openPreferences(tester);
    await tester.tap(find.text('Local + S3'));
    await tester.pump();
    await type(tester, 'directory', notesDir);
    await type(tester, 's3Endpoint', endpoint);
    await type(tester, 's3Region', region);
    await type(tester, 's3Bucket', bucket);
    await type(tester, 's3AccessKeyId', accessKey);
    await type(tester, 's3SecretAccessKey', secret);
    await tapScrolled(tester, autoLogTile);
    expect(await autoLogSwitch(tester), isTrue);

    // 2. Export: the secrets warning is on screen and in the confirmation.
    expect(find.text('The export file contains secrets'), findsOneWidget);
    await tapScrolled(tester, find.text('Export settings'));
    expect(
      find.textContaining('secret access key in plain text'),
      findsOneWidget,
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Export'));
    await pumpWithIo(tester);
    expect(find.text('Export settings to file'), findsOneWidget);
    await typePathAndConfirm(tester, exportPath, 'Save');
    expect(find.text('Settings exported to $exportPath'), findsOneWidget);

    // Export also saved the on-screen values, like the Save button.
    final stored = await SharedPreferences.getInstance();
    expect(stored.getString('StorageMode'), 'both');
    expect(session.preferredMode, StorageMode.both);

    final exported = File(exportPath);
    expect(await fileExists(tester, exported), isTrue);
    final json =
        jsonDecode((await tester.runAsync(exported.readAsString))!)
            as Map<String, Object?>;
    expect(json['app'], 'org.buetow.quicklog');
    expect(json['formatVersion'], 1);
    expect(json['containsSecrets'], isTrue);
    expect(json['settings'], {
      'directory': notesDir,
      'autoLogSharedText': true,
      'storageMode': 'both',
      's3': {
        'endpoint': endpoint,
        'region': region,
        'bucket': bucket,
        'accessKeyId': accessKey,
        'secretAccessKey': secret,
      },
    });

    // 3. Uninstall: all app data gone, new process, app back to defaults.
    await tester.pumpWidget(const SizedBox());
    session.dispose();
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await freshProcess();
    expect((await SharedPreferences.getInstance()).getKeys(), isEmpty);
    await pumpApp(tester);
    await openPreferences(tester);
    expect(await selectedMode(tester), {StorageMode.local});
    expect(await autoLogSwitch(tester), isFalse);
    expect(find.text(endpoint), findsNothing);

    // 4. Import the file through the same screen.
    await tapScrolled(tester, find.text('Import settings'));
    expect(find.text('Import settings from file'), findsOneWidget);
    await typePathAndConfirm(tester, exportPath, 'Open');
    expect(find.textContaining('Replace the current settings'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Import'));
    await pumpWithIo(tester, rounds: 20);
    expect(find.text('Settings imported.'), findsOneWidget);

    // 5. The screen reflects every value immediately...
    expect(await selectedMode(tester), {StorageMode.both});
    expect(await autoLogSwitch(tester), isTrue);
    expect(await textOf(tester, 'directory'), notesDir);
    expect(await textOf(tester, 's3Endpoint'), endpoint);
    expect(await textOf(tester, 's3Region'), region);
    expect(await textOf(tester, 's3Bucket'), bucket);
    expect(await textOf(tester, 's3AccessKeyId'), accessKey);
    expect(await textOf(tester, 's3SecretAccessKey'), secret);
    expect(session.preferredMode, StorageMode.both);

    // ...and so does storage, key for key.
    final restored = await SharedPreferences.getInstance();
    expect(restored.getString('Directory'), notesDir);
    expect(restored.getBool('AutoLogSharedText'), isTrue);
    expect(restored.getString('StorageMode'), 'both');
    expect(restored.getString('S3Endpoint'), endpoint);
    expect(restored.getString('S3Region'), region);
    expect(restored.getString('S3Bucket'), bucket);
    expect(restored.getString('S3AccessKeyId'), accessKey);
    expect(restored.getString('S3SecretAccessKey'), secret);

    // 6. Leaving Preferences with Save keeps the imported values.
    await tester.tap(find.byTooltip('Save'));
    await pumpWithIo(tester);
    expect(find.text('Quicklog'), findsOneWidget);
    expect(restored.getString('S3SecretAccessKey'), secret);
  });

  testWidgets(
    'importing a file from another app shows why and changes nothing',
    (tester) async {
      await tester.runAsync(() async {
        await File(exportPath).parent.create(recursive: true);
        await File(exportPath).writeAsString(
          jsonEncode({
            'app': 'org.buetow.someotherapp',
            'format': 'quicklog-settings',
            'formatVersion': 1,
            'settings': {'storageMode': 's3'},
          }),
        );
      });
      await pumpApp(tester);
      await openPreferences(tester);
      await tapScrolled(tester, find.text('Import settings'));
      await typePathAndConfirm(tester, exportPath, 'Open');

      expect(find.text('Import failed'), findsOneWidget);
      expect(find.textContaining('org.buetow.someotherapp'), findsOneWidget);
      expect((await SharedPreferences.getInstance()).getKeys(), isEmpty);
      expect(session.preferredMode, StorageMode.local);
    },
  );

  testWidgets('a missing file reports a read error', (tester) async {
    await pumpApp(tester);
    await openPreferences(tester);
    await tapScrolled(tester, find.text('Import settings'));
    await typePathAndConfirm(tester, p.join(tmp.path, 'nope.json'), 'Open');

    expect(find.text('Import failed'), findsOneWidget);
    expect(find.textContaining('Cannot read'), findsOneWidget);
  });
}
