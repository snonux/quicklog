import 'package:flutter/material.dart';

import '../services/entry_handle.dart';
import '../services/image_attachments.dart';
import '../services/merged_note_listing.dart';
import 'delete_confirmation_screen.dart';
import 'entry_edit_screen.dart';
import 'entry_tile.dart';

/// Viewer for a single entry. It loads the note itself so that the browser
/// does not have to read every entry up front, and it never deletes directly:
/// confirming deletion pops with `true` and the browser does the work,
/// keeping one code path for deletion and error reporting. Editing is pushed
/// on top of it, and the viewer re-reads afterwards so what is on screen
/// matches what is stored.
class EntryDetailScreen extends StatefulWidget {
  const EntryDetailScreen({
    super.key,
    required this.handle,
    this.location,
    this.saveImage,
  });

  final EntryHandle handle;
  final NoteStorageLocation? location;

  /// Passed on to the editor for "Add image".
  final ImageSaver? saveImage;

  @override
  State<EntryDetailScreen> createState() => _EntryDetailScreenState();
}

class _EntryDetailScreenState extends State<EntryDetailScreen> {
  late Future<String> _content;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  /// Kept in state rather than started in build(), so a rebuild (e.g. from
  /// the edit round-trip) does not kick off a second read.
  void _reload() {
    setState(() {
      _content = widget.handle.read();
    });
  }

  Future<void> _edit() async {
    final saved = await editEntry(
      context,
      widget.handle,
      saveImage: widget.saveImage,
    );
    // true: saved. false: discarded, or a save was attempted and may have
    // written storage. null: no save was attempted, so the text shown is
    // still current.
    if (saved != null && mounted) _reload();
  }

  Future<void> _requestDelete() async {
    final confirmed = await confirmEntryDeletion(context, widget.handle);
    if (!confirmed || !mounted) return;
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final location = widget.location;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.handle.id),
        actions: [
          if (location != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Center(
                child: Text(
                  noteLocationLabel(location),
                  style: Theme.of(context).textTheme.labelLarge,
                ),
              ),
            ),
          IconButton(
            tooltip: 'Edit entry',
            icon: const Icon(Icons.edit_outlined),
            onPressed: _edit,
          ),
          IconButton(
            tooltip: 'Delete entry',
            icon: const Icon(Icons.delete_outline),
            onPressed: _requestDelete,
          ),
        ],
      ),
      body: FutureBuilder<String>(
        future: _content,
        builder: (_, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return Center(child: Text('Error: ${snap.error}'));
          }
          return SingleChildScrollView(
            padding: const EdgeInsets.all(12),
            child: SelectableText(snap.data ?? ''),
          );
        },
      ),
    );
  }
}
