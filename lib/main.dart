import 'dart:io';

import 'package:flutter/material.dart';
import 'package:workmanager/workmanager.dart';

import 'screens/home_screen.dart';
import 'services/active_note_store.dart';
import 'services/preferences.dart';
import 'services/s3_session_controller.dart';
import 'services/s3_background_retry.dart';
import 'services/s3_retry_scheduler.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final preferences = PreferencesService();
  final session = S3SessionController(preferences: preferences);
  final activeStore = ActiveNoteStore(
    preferences: preferences,
    session: session,
  );
  activeStore.bindSessionProbe();
  await session.load(waitForRecovery: false);
  if (Platform.isAndroid) {
    await Workmanager().initialize(s3RetryCallbackDispatcher);
  }
  late final S3RetryScheduler scheduler;
  scheduler = S3RetryScheduler(
    preferences: preferences,
    retry: () async {
      final identity = await scheduler.identity();
      await activeStore.replayS3OnlyLocalNotes(
        retryWhileDegraded: true,
        stillCurrent: () async {
          await preferences.reload();
          return scheduler.isForeground &&
              await scheduler.identity() == identity;
        },
      );
    },
    onResumed: () => activeStore.replayS3OnlyLocalNotes(),
  );
  // UI-engine expiry recovery stays foreground-only. Closed-app work is
  // exclusively dispatched at the opted-in WorkManager schedule.
  activeStore.automaticRecoveryAllowed = () => scheduler.isForeground;
  S3RetryScheduler.current = scheduler;
  await scheduler.start();
  runApp(
    QuickLoggerApp(
      preferences: preferences,
      session: session,
      activeStore: activeStore,
    ),
  );
}

class QuickLoggerApp extends StatelessWidget {
  const QuickLoggerApp({
    super.key,
    required this.preferences,
    required this.session,
    required this.activeStore,
  });

  final PreferencesService preferences;
  final S3SessionController session;
  final ActiveNoteStore activeStore;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Quicklog',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.indigo,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: HomeScreen(
        preferences: preferences,
        session: session,
        activeStore: activeStore,
      ),
    );
  }
}
