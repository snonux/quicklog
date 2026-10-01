import 'dart:ui';

import 'package:flutter/widgets.dart';
import 'package:workmanager/workmanager.dart';

import 'active_note_store.dart';
import 'preferences.dart';
import 's3_retry_scheduler.dart';
import 's3_session_controller.dart';

/// WorkManager starts this entry point in its own engine without an Activity.
@pragma('vm:entry-point')
void s3RetryCallbackDispatcher() {
  Workmanager().executeTask((task, input) async {
    WidgetsFlutterBinding.ensureInitialized();
    DartPluginRegistrant.ensureInitialized();
    final identity = input?['identity'];
    if (task != s3RetryTaskName || identity is! String) return true;
    final preferences = PreferencesService();
    await preferences.reload();
    final session = S3SessionController(preferences: preferences);
    // No recovery callback is bound: the selected scheduled pass owns replay.
    await session.load();
    final store = ActiveNoteStore(preferences: preferences, session: session);
    late final S3RetryScheduler scheduler;
    Future<bool> current() async {
      await preferences.reload();
      return await preferences.s3RetryInBackground() &&
          await scheduler.identity() == identity;
    }

    scheduler = S3RetryScheduler(
      preferences: preferences,
      backgroundWorker: true,
      retry: () => store.replayS3OnlyLocalNotes(
        retryWhileDegraded: true,
        stillCurrent: current,
      ),
    );
    try {
      await scheduler.runScheduled(identity);
      return true;
    } finally {
      scheduler.dispose();
      session.dispose();
    }
  });
}
