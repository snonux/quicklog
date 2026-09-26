import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:quicklog/screens/preferences_screen.dart';
import 'package:quicklog/services/preferences.dart';
import 'package:quicklog/services/s3_session_controller.dart';
import 'package:quicklog/services/settings_backup.dart';
import 'package:quicklog/services/settings_file_service.dart';

import 'io_pump.dart';

void main() {
  late Directory tmp;
  late String unwritableDir;
  late S3SessionController session;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('ql-prefs-');
    // A directory can never be created underneath a regular file, so this is an
    // unwritable target on any platform -- and unlike chmod it needs no
    // subprocess, which a widget test's fake clock cannot wait for.
    final blocker = File(p.join(tmp.path, 'blocker'));
    await blocker.writeAsString('not a directory');
    unwritableDir = p.join(blocker.path, 'notes');
    SharedPreferences.setMockInitialValues(<String, Object>{});
    session = S3SessionController();
    await session.load();
  });

  tearDown(() async {
    session.dispose();
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  Future<void> pumpPrefs(WidgetTester tester, String directory) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'flutter.Directory': directory,
    });
    await tester.pumpWidget(
      MaterialApp(home: PreferencesScreen(session: session)),
    );
    await pumpWithIo(tester);
  }

  testWidgets('no warning when the configured directory is writable',
      (tester) async {
    // The bug this guards: the warning used to be driven by the All files
    // access permission, so a default install -- whose directory is the
    // app-owned folder that needs no permission at all -- always showed an
    // error card even though logging worked perfectly.
    await pumpPrefs(tester, tmp.path);

    expect(find.text('Cannot write to this folder'), findsNothing);
    expect(find.byIcon(Icons.folder_off), findsNothing);
  });

  testWidgets('no warning for a directory that does not exist yet',
      (tester) async {
    // The GrapheneOS Storage Scopes flow in docs/installation.md: point at a
    // folder that is not there yet and let Quicklog create it on first write.
    await pumpPrefs(tester, p.join(tmp.path, 'Vault', 'Quicklog'));

    expect(find.text('Cannot write to this folder'), findsNothing);
  });

  testWidgets('warns when the configured directory cannot be written to',
      (tester) async {
    await pumpPrefs(tester, unwritableDir);

    expect(find.text('Cannot write to this folder'), findsOneWidget);
    expect(find.byIcon(Icons.folder_off), findsOneWidget);
  });

  testWidgets('the directory field and auto-log toggle still load',
      (tester) async {
    await pumpPrefs(tester, tmp.path);

    expect(find.text('Preferences'), findsOneWidget);
    expect(find.text(tmp.path), findsOneWidget);
    expect(find.text('Auto-log shared text'), findsOneWidget);
    expect(find.text('Local only'), findsOneWidget);
    expect(find.text('S3 only'), findsOneWidget);
  });

  group('export / import with a system file dialog', () {
    late _FakeSettingsFiles files;

    Future<void> pumpWithFiles(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      files = _FakeSettingsFiles();
      SharedPreferences.setMockInitialValues(<String, Object>{
        'flutter.Directory': tmp.path,
      });
      await tester.pumpWidget(MaterialApp(
        home: PreferencesScreen(session: session, settingsFiles: files),
      ));
      await pumpWithIo(tester);
    }

    Future<void> tapButton(WidgetTester tester, String label) async {
      final finder = find.text(label);
      await tester.scrollUntilVisible(finder, 200,
          scrollable: find.byType(Scrollable).first);
      await tester.tap(finder);
      await pumpWithIo(tester);
    }

    testWidgets('shows the secrets warning next to the backup buttons',
        (tester) async {
      await pumpWithFiles(tester);
      expect(find.text('The export file contains secrets'), findsOneWidget);
      expect(find.text('Export settings'), findsOneWidget);
      expect(find.text('Import settings'), findsOneWidget);
    });

    testWidgets('cancelling the warning writes nothing', (tester) async {
      await pumpWithFiles(tester);
      await tapButton(tester, 'Export settings');
      await tester.tap(find.text('Cancel'));
      await pumpWithIo(tester);
      expect(files.saved, isNull);
    });

    testWidgets('export hands the dialog a dated name and valid JSON',
        (tester) async {
      await pumpWithFiles(tester);
      await tapButton(tester, 'Export settings');
      await tester.tap(find.widgetWithText(FilledButton, 'Export'));
      await pumpWithIo(tester);
      expect(files.suggestedName, matches(RegExp(r'^quicklog-settings-\d{6}\.json$')));
      final backup = decodeSettingsBackup(files.saved!);
      expect(backup.settings.storageMode, StorageMode.local);
      expect(backup.settings.directory, tmp.path);
      expect(find.text('Settings exported to content://picked.json'),
          findsOneWidget);
    });

    testWidgets('cancelling the file dialog is silent', (tester) async {
      await pumpWithFiles(tester);
      files.cancel = true;
      await tapButton(tester, 'Import settings');
      expect(find.text('Import failed'), findsNothing);
      expect(find.text('Import settings'), findsOneWidget);
    });

    testWidgets('a newer format version is refused with a clear message',
        (tester) async {
      await pumpWithFiles(tester);
      files.toOpen = '{"app":"org.buetow.quicklog","format":"quicklog-settings",'
          '"formatVersion":99,"settings":{}}';
      await tapButton(tester, 'Import settings');
      expect(find.text('Import failed'), findsOneWidget);
      expect(find.textContaining('Update Quicklog'), findsOneWidget);
    });

    testWidgets('a picker error is shown, not swallowed', (tester) async {
      await pumpWithFiles(tester);
      files.error = PlatformException(
          code: 'no_picker', message: 'No file manager app is available.');
      await tapButton(tester, 'Import settings');
      expect(find.text('No file manager app is available.'), findsOneWidget);
    });

    testWidgets('declining the import confirmation keeps settings',
        (tester) async {
      await pumpWithFiles(tester);
      files.toOpen = encodeSettingsBackup(
        const QuicklogSettings(storageMode: StorageMode.s3),
        exportedAt: DateTime.utc(2026),
      );
      await tapButton(tester, 'Import settings');
      expect(find.textContaining('Replace the current settings'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await pumpWithIo(tester);
      expect(session.preferredMode, StorageMode.local);
    });
  });
}

class _FakeSettingsFiles implements SettingsFileGateway {
  String? saved;
  String? suggestedName;
  String? toOpen;
  bool cancel = false;
  Object? error;

  @override
  Future<String?> save({
    required String suggestedName,
    required String content,
  }) async {
    if (error != null) throw error!;
    if (cancel) return null;
    this.suggestedName = suggestedName;
    saved = content;
    return 'content://picked.json';
  }

  @override
  Future<String?> open() async {
    if (error != null) throw error!;
    if (cancel) return null;
    return toOpen;
  }
}
