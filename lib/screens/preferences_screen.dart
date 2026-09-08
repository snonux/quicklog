import 'package:flutter/material.dart';

import '../services/active_note_store.dart';
import '../services/preferences.dart';
import '../services/s3_config.dart';
import '../services/s3_note_store.dart';
import '../services/s3_object_client.dart';
import '../services/s3_session_controller.dart';
import '../services/storage.dart';
import '../services/storage_access_service.dart';

class PreferencesScreen extends StatefulWidget {
  const PreferencesScreen({
    super.key,
    this.session,
    this.activeStore,
  });

  /// Optional override for tests; defaults to the process-wide session.
  final S3SessionController? session;

  /// Optional override for tests (inject fake S3 factory).
  final ActiveNoteStore? activeStore;

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

  Future<void> _save() async {
    await _prefs.setDirectory(_dirController.text);
    await _prefs.setAutoLogSharedText(_autoLog);
    await _prefs.setS3Config(_readS3Config());
    await _session.setPreferredMode(_storageMode);
    _active.bindSessionProbe();
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  Future<void> _testConnection() async {
    setState(() => _testing = true);
    try {
      final config = _readS3Config();
      if (!config.hasCredentials) {
        throw StateError('Enter access key and secret first.');
      }
      // Persist temporarily so the factory sees the values under test.
      await _prefs.setS3Config(config);
      final client = MinioS3ObjectClient(config);
      final store = S3NoteStore(client);
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
            _storageMode == StorageMode.s3
                ? 'Local directory is used when S3 is unavailable (degraded fallback).'
                : 'Notes are written here as Markdown files.',
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
            ],
            selected: {_storageMode},
            onSelectionChanged: (selected) {
              setState(() => _storageMode = selected.single);
            },
          ),
          const SizedBox(height: 8),
          Text(
            _storageMode == StorageMode.local
                ? 'Notes stay on this device as Markdown files. Default.'
                : 'Notes go to a user-configured S3 endpoint only. On failure '
                    'the app falls back to local until you retry or the '
                    'degrade window ends. Credentials stay on this device; '
                    'nothing is telemetried.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          if (_storageMode == StorageMode.s3) ...[
            const SizedBox(height: 16),
            const Text('S3 endpoint:',
                style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            TextField(
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
        ],
      ),
    );
  }
}
