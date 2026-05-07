import 'package:flutter/material.dart';

import '../services/preferences.dart';
import '../services/storage.dart';

class PreferencesScreen extends StatefulWidget {
  const PreferencesScreen({super.key});

  @override
  State<PreferencesScreen> createState() => _PreferencesScreenState();
}

class _PreferencesScreenState extends State<PreferencesScreen> {
  final PreferencesService _prefs = PreferencesService();
  final TextEditingController _dirController = TextEditingController();
  bool _autoLog = false;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    _dirController.text = await _prefs.directory();
    _autoLog = await _prefs.autoLogSharedText();
    if (!mounted) return;
    setState(() => _loaded = true);
  }

  Future<void> _resetToDefault() async {
    _dirController.text = await defaultLogDirectory();
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
          const Text('Directory:', style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          TextField(
            controller: _dirController,
            decoration: InputDecoration(
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                tooltip: 'Reset to default',
                icon: const Icon(Icons.restore),
                onPressed: _resetToDefault,
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
