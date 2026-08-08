import 'dart:io' show Directory, Platform;

import 'package:path_provider/path_provider.dart';

const String defaultLinuxDirectory = '.';

class QuickSwitchDirectory {
  const QuickSwitchDirectory(this.label, this.path);
  final String label;
  final String path;
}

// One-tap preference shortcuts to common Android storage locations.
// None of these are the app default; the user picks one explicitly.
const List<QuickSwitchDirectory> quickSwitchDirectories = [
  QuickSwitchDirectory('Vault/Quicklog', '/storage/emulated/0/Notes/Vault/Quicklog'),
  QuickSwitchDirectory('Vault', '/storage/emulated/0/Notes/Vault'),
  QuickSwitchDirectory('Documents', '/storage/emulated/0/Documents'),
  QuickSwitchDirectory('Download', '/storage/emulated/0/Download'),
];

Future<String> defaultLogDirectory() async {
  if (Platform.isAndroid) {
    final dir = await getExternalStorageDirectory();
    if (dir != null) return dir.path;
    return (await getApplicationDocumentsDirectory()).path;
  }
  return Directory.current.path;
}
