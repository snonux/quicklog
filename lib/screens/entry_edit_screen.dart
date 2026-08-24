import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../services/log_service.dart';

/// Pushes the full-screen editor for [entry] and reports whether it saved.
///
/// A whole screen rather than an inline field: notes can be long, and the
/// editor needs the same amount of room the compose screen gets. Returning
/// only "saved or not" keeps the caller's job trivial — refresh what it shows
/// when something changed, do nothing otherwise.
Future<bool> editEntry(BuildContext context, LogEntry entry) async {
  final saved = await Navigator.of(context).push<bool>(
    MaterialPageRoute(builder: (_) => EntryEditScreen(entry: entry)),
  );
  return saved ?? false;
}

/// Editor for an existing entry. It writes back to the same file, so the
/// note keeps its creation timestamp (which is what the filename encodes)
/// and its position in the browser list.
class EntryEditScreen extends StatefulWidget {
  const EntryEditScreen({super.key, required this.entry});

  final LogEntry entry;

  @override
  State<EntryEditScreen> createState() => _EntryEditScreenState();
}

class _EntryEditScreenState extends State<EntryEditScreen> {
  final TextEditingController _controller = TextEditingController();

  /// Text as it is on disk, used to tell "nothing changed" from "unsaved
  /// changes" for both the Save button and the discard prompt.
  String _original = '';
  bool _loading = true;
  Object? _loadError;
  bool _saving = false;

  bool get _dirty => !_loading && _controller.text != _original;

  @override
  void initState() {
    super.initState();
    // Every keystroke changes the char count and can flip the dirty state,
    // which drives the Save/Revert buttons and PopScope.canPop.
    _controller.addListener(_onTextChanged);
    _load();
  }

  @override
  void dispose() {
    _controller.removeListener(_onTextChanged);
    _controller.dispose();
    super.dispose();
  }

  void _onTextChanged() => setState(() {});

  Future<void> _load() async {
    try {
      final text = await entryContent(widget.entry.file);
      _original = text;
      _controller.text = text;
    } catch (e) {
      // Show the reason instead of an empty editor: saving an empty buffer
      // over a note that merely could not be read would destroy it.
      _loadError = e;
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    final text = _controller.text;
    try {
      await updateEntry(widget.entry.file, text);
    } catch (e) {
      // Writing can be denied for files outside the app's storage scope;
      // stay in the editor so the user does not lose what they typed.
      if (!mounted) return;
      setState(() => _saving = false);
      _showSnack('Could not save: $e', isError: true);
      return;
    }
    if (!mounted) return;
    _original = text;
    Navigator.of(context).pop(true);
  }

  /// Restores the on-disk text. Nothing is written, so this is the cheap way
  /// back out of an edit without leaving the screen.
  void _revert() {
    _controller.text = _original;
    _controller.selection = TextSelection.collapsed(offset: _original.length);
  }

  /// Back navigation while dirty. [PopScope] blocks the pop (canPop is false
  /// exactly then), so ask first and pop manually with `false`: the entry was
  /// not saved, and the caller must not refresh as if it had been.
  Future<void> _handlePop(bool didPop) async {
    if (didPop) return;
    final discard = await _confirmDiscard();
    if (discard && mounted) Navigator.of(context).pop(false);
  }

  Future<bool> _confirmDiscard() async {
    final answer = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Discard changes?'),
        content: const Text('The edits to this entry have not been saved.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Keep editing'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Discard'),
          ),
        ],
      ),
    );
    return answer ?? false;
  }

  void _showSnack(String message, {bool isError = false}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? Colors.red : null,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope<bool>(
      canPop: !_dirty && !_saving,
      onPopInvokedWithResult: (didPop, _) => _handlePop(didPop),
      child: Scaffold(
        appBar: AppBar(title: Text(p.basename(widget.entry.file.path))),
        body: SafeArea(
          child: Padding(padding: const EdgeInsets.all(12), child: _body()),
        ),
      ),
    );
  }

  Widget _body() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_loadError != null) {
      return Center(child: Text('Could not read file: $_loadError'));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(child: _editor()),
        const SizedBox(height: 8),
        _actions(),
      ],
    );
  }

  Widget _editor() {
    return TextField(
      controller: _controller,
      autofocus: true,
      maxLines: null,
      expands: true,
      textAlignVertical: TextAlignVertical.top,
      decoration: const InputDecoration(
        hintText: 'Entry text...',
        border: OutlineInputBorder(),
      ),
    );
  }

  Widget _actions() {
    // Save and Revert are only meaningful once something changed; leaving
    // them disabled otherwise also makes "unsaved" visible at a glance.
    return Row(
      children: [
        FilledButton.icon(
          onPressed: _dirty && !_saving ? _save : null,
          icon: const Icon(Icons.save),
          label: const Text('Save'),
        ),
        const SizedBox(width: 8),
        OutlinedButton(
          onPressed: _dirty && !_saving ? _revert : null,
          child: const Text('Revert'),
        ),
        const Spacer(),
        Text('${_controller.text.length} chars'),
      ],
    );
  }
}
