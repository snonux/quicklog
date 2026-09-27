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

  static Future<bool> clearSharedTextCacheIfEquals(String expected) async {
    if (!Platform.isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('clearSharedTextCacheIfEquals', {
            'expected': expected,
          }) ??
          false;
    } on MissingPluginException {
      return false;
    }
  }
}
