import 'package:flutter/material.dart';

import '../services/preferences.dart';
import '../services/storage.dart';
import '../services/storage_access_service.dart';

class PreferencesScreen extends StatefulWidget {
  const PreferencesScreen({super.key});

  @override
  State<PreferencesScreen> createState() => _PreferencesScreenState();
}

class _PreferencesScreenState extends State<PreferencesScreen> with WidgetsBindingObserver {
  final PreferencesService _prefs = PreferencesService();
  final TextEditingController _dirController = TextEditingController();
  bool _autoLog = false;
  bool _loaded = false;
  // Whether the configured directory is actually writable -- not whether the
  // All files access permission is held. See canWriteToDirectory().
  bool _directoryWritable = true;

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
    _directoryWritable = await canWriteToDirectory(_dirController.text);
    if (!mounted) return;
    setState(() => _loaded = true);
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
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _dirController.dispose();
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
