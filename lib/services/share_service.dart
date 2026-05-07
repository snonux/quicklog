import 'dart:io' show Platform;

import 'package:flutter/services.dart';

class ShareService {
  static const _channel = MethodChannel('org.buetow.quicklog/share');

  static Future<String?> readSharedTextFromCache() async {
    if (!Platform.isAndroid) return null;
    try {
      return await _channel.invokeMethod<String>('readSharedTextFromCache');
    } on MissingPluginException {
      return null;
    }
  }

  static Future<void> clearSharedTextCache() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<void>('clearSharedTextCache');
    } on MissingPluginException {
      // No-op: channel not registered (e.g. running on a non-Android target).
    }
  }
}
