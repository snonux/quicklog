import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quicklog/screens/preferences_screen.dart';
import 'package:quicklog/services/preferences.dart';
import 'package:quicklog/services/s3_session_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'io_pump.dart';

void main() {
  late Directory directory;
  late PreferencesService prefs;
  late S3SessionController session;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('ql-retry-prefs-');
    SharedPreferences.setMockInitialValues({
      'flutter.Directory': directory.path,
      'flutter.StorageMode': 's3',
      'flutter.S3RetryTimes': ['08:00', '20:15'],
    });
    prefs = PreferencesService();
    session = S3SessionController(preferences: prefs);
    await session.load();
  });
  tearDown(() async {
    session.dispose();
    await directory.delete(recursive: true);
  });

  testWidgets(
    'time picker adds a daily time and removal saves with preferences',
    (tester) async {
      tester.view.physicalSize = const Size(1000, 2200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: PreferencesScreen(preferences: prefs, session: session),
        ),
      );
      await pumpWithIo(tester);
      final add = find.byKey(const ValueKey('prefs.addRetryTime'));
      await tester.ensureVisible(add);
      await tester.pumpAndSettle();
      expect(find.text('08:00'), findsOneWidget);
      expect(find.text('20:15'), findsOneWidget);
      await tester.tap(add);
      await tester.pumpAndSettle();
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      expect(find.text('09:00'), findsOneWidget);
      final morning = find.byKey(const ValueKey('prefs.retryTime.480'));
      await tester.tap(
        find.descendant(of: morning, matching: find.byTooltip('Delete')),
      );
      await tester.pumpAndSettle();
      expect(find.text('08:00'), findsNothing);
      await tester.tap(find.byTooltip('Save'));
      await pumpWithIo(tester);
      expect((await prefs.s3RetrySchedule()).times, ['09:00', '20:15']);
    },
  );

  testWidgets('local and dual-write modes hide scheduled retries', (
    tester,
  ) async {
    await prefs.setStorageMode(StorageMode.both);
    await session.setPreferredMode(StorageMode.both);
    await tester.pumpWidget(
      MaterialApp(
        home: PreferencesScreen(preferences: prefs, session: session),
      ),
    );
    await pumpWithIo(tester);
    expect(find.byKey(const ValueKey('prefs.addRetryTime')), findsNothing);
    expect(find.text('Retry local notes daily'), findsNothing);
  });
}
