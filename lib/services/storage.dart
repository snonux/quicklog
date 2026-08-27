import 'dart:io' show Directory, File, FileSystemException, Platform;

import 'package:path/path.dart' as p;
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

/// Whether Quicklog can actually write log entries into [path].
///
/// This mirrors what [logEntry] does -- create the directory if it is missing,
/// then write a file into it -- because "can we write here?" is the only
/// question worth asking the user about.
///
/// Asking the MANAGE_EXTERNAL_STORAGE permission instead gives the wrong
/// answer in both directions. The default app-specific directory needs no
/// permission at all, so a fresh install would be warned about a folder it can
/// write to perfectly well. And under GrapheneOS Storage Scopes the app is
/// deliberately told it has no access while writes to folders it created still
/// succeed -- exactly the setup docs/installation.md recommends.
///
/// Checking leaves the filesystem as it found it: a directory created only to
/// run the probe is removed again.
Future<bool> canWriteToDirectory(String path) async {
  if (path.trim().isEmpty) return false;
  final dir = Directory(path);
  final probe = File(p.join(path, '.quicklog-write-probe'));
  var created = false;
  try {
    created = !await dir.exists();
    await dir.create(recursive: true);
    await probe.writeAsString('');
    return true;
  } on FileSystemException {
    return false;
  } finally {
    try {
      if (await probe.exists()) await probe.delete();
      if (created && await dir.exists()) await dir.delete();
    } on FileSystemException {
      // Best effort. Failing to tidy up does not change the answer, and the
      // directory would be reused by the next log entry anyway.
    }
  }
}
