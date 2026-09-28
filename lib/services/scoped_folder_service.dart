import 'package:flutter/services.dart';

/// The picker persists Android's read/write grant before returning a tree.
/// The URI is opaque and must only be passed to the SAF note store.
class ScopedFolder {
  const ScopedFolder(this.uri, this.name);

  final String uri;
  final String name;
}

class ScopedFolderService {
  const ScopedFolderService({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('org.buetow.quicklog/saf');

  final MethodChannel _channel;

  Future<ScopedFolder?> pick() async {
    final value = await _channel.invokeMapMethod<String, String>('pickTree');
    if (value == null) return null;
    final uri = value['uri'];
    final name = value['name'];
    if (uri == null || uri.isEmpty || name == null || name.isEmpty) {
      throw StateError('The folder picker returned an incomplete selection.');
    }
    return ScopedFolder(uri, name);
  }

  /// Drop a grant acquired by a picker choice that was never saved.
  Future<void> release(String uri) async {
    try {
      await _channel.invokeMethod<void>('releaseTree', {'uri': uri});
    } on MissingPluginException {
      // No Android provider (desktop/test).
    }
  }
}
