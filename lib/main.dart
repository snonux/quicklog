import 'package:flutter/material.dart';

import 'screens/home_screen.dart';

void main() {
  runApp(const QuickLoggerApp());
}

class QuickLoggerApp extends StatelessWidget {
  const QuickLoggerApp({super.key});

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
      home: const HomeScreen(),
    );
  }
}
