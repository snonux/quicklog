import 'package:flutter/services.dart';

class StorageAccessService {
  static const _channel = MethodChannel('org.buetow.quicklog/share');

  static Future<int?> storageApiLevel() async {
    try {
      return await _channel.invokeMethod<int>('storageApiLevel');
    } on MissingPluginException {
      return null;
    }
  }

  static Future<void> requestStorageAccess() async {
    try {
      await _channel.invokeMethod<void>('requestStorageAccess');
    } on MissingPluginException {
      // No-op: channel not registered (e.g. running on a non-Android target).
    }
  }
}

String storageAccessWarning(int? androidApiLevel) {
  if (androidApiLevel != null && androidApiLevel < 30) {
    return 'Quicklog needs Storage permission for this folder on Android 7–10. '
        'Tap to request it. If no dialog appears, enable Storage in '
        'Settings → Apps → Quicklog → Permissions. Check the folder path if '
        'access still fails.';
  }
  if (androidApiLevel != null) {
    return 'Quicklog needs All files access for this folder on Android 11+. '
        'Tap to grant it in Settings. Check the folder path if access still fails.';
  }
  return 'Quicklog cannot write to this folder. Check its path and permissions.';
}
