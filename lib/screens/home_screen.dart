import 'dart:io';

import 'package:flutter/material.dart';

import '../services/log_service.dart';
import '../services/preferences.dart';
import '../services/share_service.dart';
import '../services/shared_text_handler.dart';
import 'entry_browser_screen.dart';
import 'preferences_screen.dart';

const int kMaxTextLength = 5000;

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  final PreferencesService _prefs = PreferencesService();
  bool _warnShown = false;
  bool _loadingShared = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _controller.addListener(_onTextChanged);
    if (Platform.isAndroid) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _loadSharedText());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller.removeListener(_onTextChanged);
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && Platform.isAndroid) {
      _loadSharedText();
    }
  }

  void _onTextChanged() {
    final length = _controller.text.length;
    if (_loadingShared) {
      _warnShown = false;
      setState(() {});
      return;
    }
    if (length > kMaxTextLength && !_warnShown) {
      _warnShown = true;
      _showLengthWarning(length);
    } else if (length <= kMaxTextLength) {
      _warnShown = false;
    }
    setState(() {});
  }

  void _showLengthWarning(int length) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Text Limit'),
        content: Text(
          'Text is getting long ($length chars). Consider logging to avoid '
          'performance issues.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('OK')),
        ],
      ),
    );
  }

  void _resetInput() {
    _controller.clear();
    _warnShown = false;
    setState(() {});
  }

  Future<void> _logText() async {
    final dir = await _prefs.directory();
    try {
      await logEntry(dir, _controller.text);
      _resetInput();
    } catch (e) {
      _showError(e);
    }
  }

  void _showError(Object error) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Error: $error'), backgroundColor: Colors.red),
    );
  }

  void _showInfo(String title, String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _loadSharedText() async {
    final txt = await ShareService.readSharedTextFromCache();
    if (txt == null || txt.isEmpty) return;
    _loadingShared = true;
    final dir = await _prefs.directory();
    final autoLog = await _prefs.autoLogSharedText();
    await handleSharedTextLoad(
      text: txt,
      autoLog: autoLog,
      dir: dir,
      prefill: (s) {
        _controller.text = s;
        _controller.selection = TextSelection.collapsed(offset: s.length);
      },
      focus: () => _focusNode.requestFocus(),
      resetInput: _resetInput,
      clearCache: ShareService.clearSharedTextCache,
      logFn: (d, t) async {
        await logEntry(d, t);
      },
      showInfo: _showInfo,
      showError: _showError,
    );
    _loadingShared = false;
    if (mounted) setState(() {});
  }

  Future<void> _openPreferences() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const PreferencesScreen()),
    );
  }

  Future<void> _openEntryBrowser() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const EntryBrowserScreen()),
    );
  }

  void _showAbout() {
    showAboutDialog(
      context: context,
      applicationName: 'Quicklog',
      applicationVersion: '0.1.2',
      applicationIcon: Image.asset('logo-small.png', width: 48, height: 48),
      applicationLegalese: 'Jot timestamped markdown notes.',
    );
  }

  @override
  Widget build(BuildContext context) {
    final length = _controller.text.length;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Quicklog'),
        actions: [
          IconButton(
            tooltip: 'Browse entries',
            icon: const Icon(Icons.list),
            onPressed: _openEntryBrowser,
          ),
          IconButton(
            tooltip: 'Preferences',
            icon: const Icon(Icons.settings),
            onPressed: _openPreferences,
          ),
          IconButton(
            tooltip: 'About',
            icon: const Icon(Icons.info_outline),
            onPressed: _showAbout,
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: TextField(
                controller: _controller,
                focusNode: _focusNode,
                maxLines: null,
                expands: true,
                textAlignVertical: TextAlignVertical.top,
                decoration: const InputDecoration(
                  hintText: 'Enter text here...',
                  border: OutlineInputBorder(),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                FilledButton.icon(
                  onPressed: _logText,
                  icon: const Icon(Icons.save),
                  label: const Text('Log text'),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                  onPressed: () {
                    _resetInput();
                    _focusNode.requestFocus();
                  },
                  child: const Text('Clear'),
                ),
                const Spacer(),
                Text('$length chars'),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
