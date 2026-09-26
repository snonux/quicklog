import 'dart:io' show Directory, File, FileSystemException, Platform;

import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;

/// Saves and opens the settings export file at a location the user chooses.
abstract class SettingsFileGateway {
  /// Writes [content] somewhere the user picks, starting from [suggestedName].
  /// Returns a description of where it went, or null when the user cancelled.
  Future<String?> save({
    required String suggestedName,
    required String content,
  });

  /// Reads a file the user picks. Returns its text, or null when cancelled.
  Future<String?> open();
}

/// Default file name for an export made at [now], e.g.
/// `quicklog-settings-260926.json`.
String suggestedSettingsFileName(DateTime now) =>
    'quicklog-settings-${DateFormat('yyMMdd').format(now)}.json';

/// Android: the system Storage Access Framework dialogs (Create document /
/// Open document), implemented in MainActivity. No extra permissions and no
/// third-party picker library, so the F-Droid build stays dependency-free.
class AndroidSettingsFileGateway implements SettingsFileGateway {
  const AndroidSettingsFileGateway();

  static const _channel = MethodChannel('org.buetow.quicklog/settings');

  @override
  Future<String?> save({
    required String suggestedName,
    required String content,
  }) {
    return _channel.invokeMethod<String>('saveSettingsFile', {
      'name': suggestedName,
      'content': content,
    });
  }

  @override
  Future<String?> open() => _channel.invokeMethod<String>('openSettingsFile');
}

/// Asks the user for a file path. [forSave] tells the prompt whether the path
/// is about to be written or read. Returns null when cancelled.
typedef SettingsPathPrompt =
    Future<String?> Function({
      required bool forSave,
      required String initialPath,
    });

/// Desktop (Linux): the user types or edits a path, the same way the log
/// directory is chosen in Preferences. Avoids depending on a desktop portal
/// or zenity being installed.
class PathPromptSettingsFileGateway implements SettingsFileGateway {
  PathPromptSettingsFileGateway(this.prompt, {String? homeDirectory})
    : _home =
          homeDirectory ??
          Platform.environment['HOME'] ??
          Directory.current.path;

  final SettingsPathPrompt prompt;
  final String _home;
  String? _lastPath;

  @override
  Future<String?> save({
    required String suggestedName,
    required String content,
  }) async {
    final initial = _lastPath == null
        ? p.join(_home, suggestedName)
        : p.join(p.dirname(_lastPath!), suggestedName);
    final path = await prompt(forSave: true, initialPath: initial);
    if (path == null || path.trim().isEmpty) return null;
    final file = File(_expand(path.trim()));
    try {
      await file.parent.create(recursive: true);
      await file.writeAsString(content, flush: true);
    } on FileSystemException catch (e) {
      throw FileSystemException('Cannot write ${file.path}', e.path, e.osError);
    }
    _lastPath = file.path;
    return file.path;
  }

  @override
  Future<String?> open() async {
    final path = await prompt(
      forSave: false,
      initialPath: _lastPath ?? '${p.normalize(_home)}${p.separator}',
    );
    if (path == null || path.trim().isEmpty) return null;
    final file = File(_expand(path.trim()));
    final String text;
    try {
      text = await file.readAsString();
    } on FileSystemException catch (e) {
      throw FileSystemException('Cannot read ${file.path}', e.path, e.osError);
    }
    _lastPath = file.path;
    return text;
  }

  String _expand(String path) {
    if (path == '~') return _home;
    if (path.startsWith('~/')) return p.join(_home, path.substring(2));
    return path;
  }
}
