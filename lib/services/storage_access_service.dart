import 'dart:io' show Platform;

import 'package:flutter/services.dart';

class StorageAccessService {
  static const _channel = MethodChannel('org.buetow.quicklog/share');

  static Future<bool> hasAllFilesAccess() async {
    if (!Platform.isAndroid) return true;
    try {
      return await _channel.invokeMethod<bool>('hasAllFilesAccess') ?? true;
    } on MissingPluginException {
      return true;
    }
  }

  static Future<void> requestAllFilesAccess() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<void>('requestAllFilesAccess');
    } on MissingPluginException {
      // No-op: channel not registered (e.g. running on a non-Android target).
    }
  }
}
