import 'package:flutter/material.dart';

import '../services/dual_write_s3_repair.dart';
import '../services/entry_handle.dart';
import '../services/image_attachments.dart';
import '../widgets/image_insert_buttons.dart';

/// Pushes the full-screen editor for [handle] and returns how it closed.
///
/// A whole screen rather than an inline field: notes can be long, and the
/// editor needs the same amount of room the compose screen gets. `true` means
/// the note was saved. `false` means the user left without a successful save
/// after either discarding edits or attempting a save (which may have written
/// one backend). `null` means no save was attempted.
///
/// With [saveImage] the editor offers "Add image" (gallery or camera).
Future<bool?> editEntry(
  BuildContext context,
  EntryHandle handle, {
  ImageSaver? saveImage,
}) {
  return Navigator.of(context).push<bool>(
    MaterialPageRoute(
      builder: (_) => EntryEditScreen(handle: handle, saveImage: saveImage),
    ),
  );
}

/// Editor for an existing entry. It writes back to the same id, so the note
/// keeps its creation timestamp (which is what the filename encodes) and its
/// position in the browser list.
class EntryEditScreen extends StatefulWidget {
  const EntryEditScreen({
    super.key,
    required this.handle,
    this.saveImage,
    this.pickImage,
    this.cameraSupported,
  });

  final EntryHandle handle;

  /// Saves an added image next to the notes; null hides "Add image".
  final ImageSaver? saveImage;

  /// Optional overrides for tests, see [ImageInsertButtons].
  final ImagePickFn? pickImage;
  final bool? cameraSupported;

  @override
  State<EntryEditScreen> createState() => _EntryEditScreenState();
}

class _EntryEditScreenState extends State<EntryEditScreen> {
  final TextEditingController _controller = TextEditingController();

  /// Text loaded for this visit, used to tell "nothing changed" from "unsaved
  /// changes" for both the Save button and the discard prompt. A failed save
  /// can leave different text on disk; this stays the loaded value.
  String _original = '';
  bool _loading = true;
  Object? _loadError;
  bool _saving = false;

  /// Set before [EntryHandle.update] is awaited. A throw after a partial write
  /// still counts: a later back is not a clean exit, even if the field is
  /// put back to [_original].
  bool _saveAttempted = false;

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
      final text = await widget.handle.read();
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
    setState(() {
      _saving = true;
      // Before the await, so a throw after one backend was written still
      // counts as an attempt.
      _saveAttempted = true;
    });
    final text = _controller.text;
    try {
      await widget.handle.update(text);
    } on DualWriteS3Pending catch (e) {
      // The device has the new text. Treat the field as saved so Back does
      // not call it unsaved, and stay so the message remains visible.
      // Don't prefix "Could not save". Leaving pops false; the browser
      // replays the queued upload without re-listing every row.
      if (!mounted) return;
      _original = text;
      setState(() => _saving = false);
      _showSnack('$e', isError: true);
      return;
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

  /// Puts the field back to the text loaded for this visit. Nothing is
  /// written, so a partial update from a failed save stays on disk.
  void _revert() {
    _controller.text = _original;
    _controller.selection = TextSelection.collapsed(offset: _original.length);
  }

  /// Back navigation. [PopScope] lets the route pop on its own only when the
  /// field is clean, nothing is saving, and no update was attempted — that
  /// result is `null`. While a save is in flight, back does nothing and does
  /// not ask to discard: the editor stays until [EntryHandle.update] finishes,
  /// and a successful save pops `true` itself. A failed save clears
  /// [_saving], after which a dirty field still asks and Discard pops
  /// `false`, and a clean field after an attempted save pops `false` with no
  /// dialog (the attempt may have written one backend).
  Future<void> _handlePop(bool didPop) async {
    if (didPop || _saving) return;
    if (!_dirty) {
      if (mounted) Navigator.of(context).pop(false);
      return;
    }
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
      canPop: !_dirty && !_saving && !_saveAttempted,
      onPopInvokedWithResult: (didPop, _) => _handlePop(didPop),
      child: Scaffold(
        appBar: AppBar(title: Text(widget.handle.id)),
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
        if (widget.saveImage case final saveImage?)
          ImageInsertButtons(
            controller: _controller,
            saveImage: saveImage,
            enabled: !_saving,
            pickImage: widget.pickImage ?? pickWithImagePicker,
            cameraSupported: widget.cameraSupported,
          ),
        Expanded(
          child: Text(
            '${_controller.text.length} chars',
            textAlign: TextAlign.end,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}
