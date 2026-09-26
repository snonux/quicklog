import 'dart:io' show FileSystemException, Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show PlatformException;

import '../services/active_note_store.dart';
import '../services/preferences.dart';
import '../services/s3_config.dart';
import '../services/s3_note_store.dart';
import '../services/s3_object_client.dart';
import '../services/s3_session_controller.dart';
import '../services/settings_backup.dart';
import '../services/settings_file_service.dart';
import '../services/storage.dart';
import '../services/storage_access_service.dart';

class PreferencesScreen extends StatefulWidget {
  const PreferencesScreen({
    super.key,
    this.session,
    this.activeStore,
    this.s3ClientFactory,
    this.settingsFiles,
  });

  /// Optional override for tests; defaults to the process-wide session.
  final S3SessionController? session;

  /// Optional override for tests (inject fake S3 factory).
  final ActiveNoteStore? activeStore;

  /// Optional client factory for "Test connection" (defaults to Minio).
  /// Injected in tests so the probe never hits the network or prefs.
  final S3ObjectClientFactory? s3ClientFactory;

  /// Where Export / Import settings save and read the file. Defaults to the
  /// Android system file dialogs, or a typed path elsewhere (Linux).
  final SettingsFileGateway? settingsFiles;

  @override
  State<PreferencesScreen> createState() => _PreferencesScreenState();
}

class _PreferencesScreenState extends State<PreferencesScreen>
    with WidgetsBindingObserver {
  final PreferencesService _prefs = PreferencesService();
  final TextEditingController _dirController = TextEditingController();
  final TextEditingController _endpointController = TextEditingController();
  final TextEditingController _regionController = TextEditingController();
  final TextEditingController _bucketController = TextEditingController();
  final TextEditingController _accessKeyController = TextEditingController();
  final TextEditingController _secretController = TextEditingController();
  bool _autoLog = false;
  StorageMode _storageMode = StorageMode.local;
  bool _loaded = false;
  bool _testing = false;
  // Whether the configured directory is actually writable -- not whether the
  // All files access permission is held. See canWriteToDirectory().
  bool _directoryWritable = true;
  bool _transferring = false;
  late final SettingsFileGateway _files = widget.settingsFiles ??
      (Platform.isAndroid
          ? const AndroidSettingsFileGateway()
          : PathPromptSettingsFileGateway(_promptForPath));

  S3SessionController get _session =>
      widget.session ?? S3SessionController.instance;

  ActiveNoteStore get _active =>
      widget.activeStore ?? ActiveNoteStore.instance;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // The user may have just granted access in Settings, so re-probe rather
      // than trust what we found when the screen opened.
      canWriteToDirectory(_dirController.text).then((writable) {
        if (mounted) setState(() => _directoryWritable = writable);
      });
    }
  }

  Future<void> _load() async {
    _dirController.text = await _prefs.directory();
    _autoLog = await _prefs.autoLogSharedText();
    _storageMode = await _prefs.storageMode();
    final s3 = await _prefs.s3Config();
    _endpointController.text = s3.endpoint;
    _regionController.text = s3.region;
    _bucketController.text = s3.bucket;
    _accessKeyController.text = s3.accessKeyId;
    _secretController.text = s3.secretAccessKey;
    _directoryWritable = await canWriteToDirectory(_dirController.text);
    if (!mounted) return;
    setState(() => _loaded = true);
  }

  S3Config _readS3Config() {
    return S3Config(
      endpoint: _endpointController.text.trim().isEmpty
          ? kDefaultS3Endpoint
          : _endpointController.text.trim(),
      region: _regionController.text.trim().isEmpty
          ? kDefaultS3Region
          : _regionController.text.trim(),
      bucket: _bucketController.text.trim().isEmpty
          ? kDefaultS3Bucket
          : _bucketController.text.trim(),
      accessKeyId: _accessKeyController.text,
      secretAccessKey: _secretController.text,
    );
  }

  Future<void> _requestAllFilesAccess() async {
    await StorageAccessService.requestAllFilesAccess();
  }

  Future<void> _resetToDefault() async {
    _dirController.text = await defaultLogDirectory();
    setState(() {});
  }

  void _useQuickSwitchDirectory(String path) {
    _dirController.text = path;
    setState(() {});
  }

  Future<void> _persist() async {
    await _prefs.setDirectory(_dirController.text);
    await _prefs.setAutoLogSharedText(_autoLog);
    await _prefs.setS3Config(_readS3Config());
    await _session.setPreferredMode(_storageMode);
    _active.bindSessionProbe();
  }

  Future<void> _save() async {
    await _persist();
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  SettingsBackupService get _backup =>
      SettingsBackupService(preferences: _prefs, session: _session);

  Future<void> _exportSettings() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.warning_amber),
        title: const Text('Export settings'),
        content: const Text(
          'The settings shown here are saved first, then written to a file. '
          'The file contains your S3 access key ID and secret access key in '
          'plain text: anyone who gets it can use your bucket. Keep it '
          'somewhere private and delete it once restored.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Export'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _transferring = true);
    try {
      await _persist();
      final json = await _backup.exportJson();
      final where = await _files.save(
        suggestedName: suggestedSettingsFileName(DateTime.now()),
        content: json,
      );
      if (where == null || !mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Settings exported to $where')),
      );
    } catch (e) {
      await _showFailure('Export failed', e);
    } finally {
      if (mounted) setState(() => _transferring = false);
    }
  }

  Future<void> _importSettings() async {
    setState(() => _transferring = true);
    try {
      final text = await _files.open();
      if (text == null || !mounted) return;
      final backup = decodeSettingsBackup(text);
      final exportedAt = backup.exportedAt;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Import settings'),
          content: Text(
            'Replace the current settings with the ones in this file'
            '${exportedAt == null ? '' : ' (exported ${exportedAt.toLocal()})'}?'
            ' Unsaved changes on this screen are discarded.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Import'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
      await _backup.apply(backup.settings);
      _active.bindSessionProbe();
      await _load();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Settings imported.')),
      );
    } catch (e) {
      await _showFailure('Import failed', e);
    } finally {
      if (mounted) setState(() => _transferring = false);
    }
  }

  Future<void> _showFailure(String title, Object error) async {
    if (!mounted) return;
    final message = switch (error) {
      SettingsImportException(:final message) => message,
      FileSystemException(:final message, :final osError) =>
        osError == null ? message : '$message: ${osError.message}',
      PlatformException(:final message, :final code) => message ?? code,
      _ => '$error',
    };
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  Future<String?> _promptForPath({
    required bool forSave,
    required String initialPath,
  }) {
    return showDialog<String>(
      context: context,
      builder: (_) =>
          _SettingsPathDialog(forSave: forSave, initialPath: initialPath),
    );
  }

  Future<void> _testConnection() async {
    setState(() => _testing = true);
    try {
      final config = _readS3Config();
      if (!config.hasCredentials) {
        throw StateError('Enter access key and secret first.');
      }
      // Probe in-memory only — never persist secrets before Save.
      final factory =
          widget.s3ClientFactory ?? ((c) => MinioS3ObjectClient(c));
      final store = S3NoteStore(factory(config));
      await store.probe();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('S3 connection OK.')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('S3 test failed: $e'),
          backgroundColor: Colors.red,
        ),
      );
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _dirController.dispose();
    _endpointController.dispose();
    _regionController.dispose();
    _bucketController.dispose();
    _accessKeyController.dispose();
    _secretController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('Preferences'),
        actions: [
          IconButton(
            tooltip: 'Save',
            icon: const Icon(Icons.check),
            onPressed: _save,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          if (!_directoryWritable) ...[
            Card(
              color: Theme.of(context).colorScheme.errorContainer,
              child: ListTile(
                leading: const Icon(Icons.folder_off),
                title: const Text('Cannot write to this folder'),
                subtitle: const Text(
                  'Quicklog needs "All files access" to write outside its own app '
                  'folder (e.g. a synced notes vault). Tap to grant it in Settings.',
                ),
                onTap: _requestAllFilesAccess,
              ),
            ),
            const SizedBox(height: 12),
          ],
          const Text('Directory:', style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          TextField(
            key: const ValueKey('prefs.directory'),
            controller: _dirController,
            decoration: InputDecoration(
              border: const OutlineInputBorder(),
              suffixIcon: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  PopupMenuButton<String>(
                    tooltip: 'Quick switch directory',
                    icon: const Icon(Icons.bolt),
                    onSelected: _useQuickSwitchDirectory,
                    itemBuilder: (context) => [
                      for (final d in quickSwitchDirectories)
                        PopupMenuItem(value: d.path, child: Text(d.label)),
                    ],
                  ),
                  IconButton(
                    tooltip: 'Reset to default',
                    icon: const Icon(Icons.restore),
                    onPressed: _resetToDefault,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            _storageMode == StorageMode.local
                ? 'Notes are written here as Markdown files.'
                : _storageMode == StorageMode.both
                    ? 'Every note is written here and mirrored to S3.'
                    : 'Local directory is used when S3 is unavailable '
                        '(degraded fallback).',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 16),
          const Text('Storage:', style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          SegmentedButton<StorageMode>(
            segments: const [
              ButtonSegment(
                value: StorageMode.local,
                label: Text('Local only'),
                icon: Icon(Icons.folder),
              ),
              ButtonSegment(
                value: StorageMode.s3,
                label: Text('S3 only'),
                icon: Icon(Icons.cloud),
              ),
              ButtonSegment(
                value: StorageMode.both,
                label: Text('Local + S3'),
                icon: Icon(Icons.cloud_done),
              ),
            ],
            selected: {_storageMode},
            onSelectionChanged: (selected) {
              setState(() => _storageMode = selected.single);
            },
          ),
          const SizedBox(height: 8),
          Text(
            switch (_storageMode) {
              StorageMode.local =>
                  'Notes stay on this device as Markdown files. Default.',
              StorageMode.s3 =>
                  'Notes go to a user-configured S3 endpoint only. On failure '
                  'the app falls back to local until you retry or the '
                  'degrade window ends. Credentials stay on this device; '
                  'nothing is telemetried.',
              StorageMode.both =>
                  'Every note is written to this directory and to S3. If S3 '
                  'is unavailable the note is still saved locally. '
                  'Credentials stay on this device; nothing is telemetried.',
            },
            style: Theme.of(context).textTheme.bodySmall,
          ),
          if (_storageMode.writesToS3) ...[
            const SizedBox(height: 16),
            const Text('S3 endpoint:',
                style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            TextField(
              key: const ValueKey('prefs.s3Endpoint'),
              controller: _endpointController,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                hintText: kDefaultS3Endpoint,
              ),
              autocorrect: false,
              enableSuggestions: false,
            ),
            const SizedBox(height: 12),
            const Text('Region:', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            TextField(
              key: const ValueKey('prefs.s3Region'),
              controller: _regionController,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                hintText: kDefaultS3Region,
              ),
              autocorrect: false,
              enableSuggestions: false,
            ),
            const SizedBox(height: 12),
            const Text('Bucket:', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            TextField(
              key: const ValueKey('prefs.s3Bucket'),
              controller: _bucketController,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                hintText: kDefaultS3Bucket,
              ),
              autocorrect: false,
              enableSuggestions: false,
            ),
            const SizedBox(height: 12),
            const Text('Access key ID:',
                style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            TextField(
              key: const ValueKey('prefs.s3AccessKeyId'),
              controller: _accessKeyController,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
              ),
              autocorrect: false,
              enableSuggestions: false,
            ),
            const SizedBox(height: 12),
            const Text('Secret access key:',
                style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            TextField(
              key: const ValueKey('prefs.s3SecretAccessKey'),
              controller: _secretController,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
              ),
              obscureText: true,
              autocorrect: false,
              enableSuggestions: false,
            ),
            const SizedBox(height: 8),
            Text(
              'On a laptop, paste values from ~/.config/garage/quicklog.env. '
              'Secrets are stored only in on-device preferences and are never logged.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                onPressed: _testing ? null : _testConnection,
                icon: _testing
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.wifi_tethering),
                label: Text(_testing ? 'Testing…' : 'Test connection'),
              ),
            ),
          ],
          const SizedBox(height: 16),
          SwitchListTile(
            title: const Text('Auto-log shared text'),
            subtitle: const Text(
              'When enabled, text shared from other apps is logged immediately '
              'instead of prefilled into the editor.',
            ),
            value: _autoLog,
            onChanged: (v) => setState(() => _autoLog = v),
          ),
          const Divider(height: 32),
          const Text('Backup:', style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          Text(
            'Export every setting to a file you choose, and import it later '
            '(e.g. after reinstalling) to restore them. Notes are not '
            'included; they live in the log directory or bucket.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          Card(
            color: Theme.of(context).colorScheme.tertiaryContainer,
            child: const ListTile(
              leading: Icon(Icons.key),
              title: Text('The export file contains secrets'),
              subtitle: Text(
                'Your S3 access key and secret are stored in it in plain '
                'text. Keep it private.',
              ),
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: _transferring ? null : _exportSettings,
                icon: const Icon(Icons.upload_file),
                label: const Text('Export settings'),
              ),
              OutlinedButton.icon(
                onPressed: _transferring ? null : _importSettings,
                icon: const Icon(Icons.download),
                label: const Text('Import settings'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Path entry for Export / Import settings on desktop, where there is no
/// system file dialog to lean on. Owns its controller so it outlives the
/// dialog's closing animation.
class _SettingsPathDialog extends StatefulWidget {
  const _SettingsPathDialog({required this.forSave, required this.initialPath});

  final bool forSave;
  final String initialPath;

  @override
  State<_SettingsPathDialog> createState() => _SettingsPathDialogState();
}

class _SettingsPathDialogState extends State<_SettingsPathDialog> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initialPath);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() => Navigator.of(context).pop(_controller.text);

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(
        widget.forSave ? 'Export settings to file' : 'Import settings from file',
      ),
      content: TextField(
        key: const ValueKey('settingsPathField'),
        controller: _controller,
        autofocus: true,
        decoration: const InputDecoration(
          border: OutlineInputBorder(),
          labelText: 'File path',
        ),
        autocorrect: false,
        enableSuggestions: false,
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _submit,
          child: Text(widget.forSave ? 'Save' : 'Open'),
        ),
      ],
    );
  }
}
