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

  /// One-shot process-local flag: true when this activity instance was
  /// brought forward for a share. Cleared on consume; not persisted across
  /// process death, so a later cold start with leftover cache stays up.
  static Future<bool> consumeShareHandoff() async {
    if (!Platform.isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('consumeShareHandoff') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// Returns Quicklog to the background after an auto-logged share so the
  /// previous app stays in front. Returns whether the activity reported that
  /// it moved to the back. No-op off Android or when the plugin is missing.
  static Future<bool> moveTaskToBack() async {
    if (!Platform.isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('moveTaskToBack') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }
}
