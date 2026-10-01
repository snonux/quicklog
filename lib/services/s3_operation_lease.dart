import 'dart:io';

import 'package:flutter/services.dart';

/// A native process-wide lease crosses Flutter engine/isolate boundaries.
/// Busy callers return immediately; engine teardown also releases the lease.
class S3OperationLease {
  S3OperationLease({MethodChannel? channel, bool? android})
    : _channel = channel ?? const MethodChannel('org.buetow.quicklog/s3-lease'),
      _android = android ?? Platform.isAndroid;

  final MethodChannel _channel;
  final bool _android;
  static int _sequence = 0;
  static String? _desktopToken;
  String? _token;

  Future<bool> acquire() async {
    if (_token != null) return false;
    final token = '${DateTime.now().microsecondsSinceEpoch}.${_sequence++}';
    if (!_android) {
      if (_desktopToken != null) return false;
      _desktopToken = token;
    }
    if (_android &&
        await _channel.invokeMethod<bool>('acquire', {'token': token}) !=
            true) {
      return false;
    }
    _token = token;
    return true;
  }

  Future<void> release() async {
    final token = _token;
    if (_android && token != null) {
      await _channel.invokeMethod<void>('release', {'token': token});
    }
    if (!_android && token != null && _desktopToken == token) {
      _desktopToken = null;
    }
    _token = null;
  }
}

/// Another Flutter engine currently owns the S3 write lane.
class S3OperationBusy implements Exception {
  const S3OperationBusy();
  @override
  String toString() => 'S3 is busy syncing another note. Try again shortly.';
}
