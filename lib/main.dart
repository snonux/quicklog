import 'package:flutter/material.dart';

import 'screens/home_screen.dart';
import 'services/active_note_store.dart';
import 'services/preferences.dart';
import 'services/s3_session_controller.dart';

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
