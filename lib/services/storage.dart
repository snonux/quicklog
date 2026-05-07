import 'dart:io' show Directory, Platform;

import 'package:path_provider/path_provider.dart';

const String defaultLinuxDirectory = '.';

Future<String> defaultLogDirectory() async {
  if (Platform.isAndroid) {
    final dir = await getExternalStorageDirectory();
    if (dir != null) return dir.path;
    return (await getApplicationDocumentsDirectory()).path;
  }
  return Directory.current.path;
}
