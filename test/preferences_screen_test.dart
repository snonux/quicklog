import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:quicklog/screens/preferences_screen.dart';

import 'io_pump.dart';

void main() {
  late Directory tmp;
  late String unwritableDir;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('ql-prefs-');
    // A directory can never be created underneath a regular file, so this is an
    // unwritable target on any platform -- and unlike chmod it needs no
    // subprocess, which a widget test's fake clock cannot wait for.
    final blocker = File(p.join(tmp.path, 'blocker'));
    await blocker.writeAsString('not a directory');
    unwritableDir = p.join(blocker.path, 'notes');
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  Future<void> pumpPrefs(WidgetTester tester, String directory) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'flutter.Directory': directory,
    });
    await tester.pumpWidget(const MaterialApp(home: PreferencesScreen()));
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
  });
}
