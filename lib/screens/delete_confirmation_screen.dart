import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;

import '../services/log_service.dart';

final _displayFormat = DateFormat('yyyy-MM-dd HH:mm:ss');

/// How much of the entry is shown on the confirmation screen. Entries can be
/// several thousand characters long (see kMaxTextLength), and the point here
/// is only to let the user recognise the note, not to read it in full.
const int kDeletePreviewChars = 800;

/// Pushes the full-screen delete confirmation and reports the user's answer.
///
/// A whole screen rather than an AlertDialog: deletion is irreversible (the
/// file is unlinked, there is no trash), so the user gets the filename, the
/// timestamp and a preview of the actual text before committing. It only
/// asks — the caller owns the deletion so that error handling and the list
/// refresh live in one place.
Future<bool> confirmEntryDeletion(BuildContext context, LogEntry entry) async {
  final confirmed = await Navigator.of(context).push<bool>(
    MaterialPageRoute(builder: (_) => DeleteConfirmationScreen(entry: entry)),
  );
  return confirmed ?? false;
}

class DeleteConfirmationScreen extends StatelessWidget {
  const DeleteConfirmationScreen({super.key, required this.entry});

  final LogEntry entry;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Delete entry?')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _header(context),
              const SizedBox(height: 16),
              Expanded(child: _preview(context)),
              const SizedBox(height: 16),
              _actions(context),
            ],
          ),
        ),
      ),
    );
  }

  Widget _header(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.warning_amber_rounded, color: theme.colorScheme.error),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                p.basename(entry.file.path),
                style: theme.textTheme.titleMedium,
              ),
              const SizedBox(height: 4),
              Text(
                _displayFormat.format(entry.timestamp),
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 8),
              Text(
                'This permanently deletes the file. It cannot be undone.',
                style: theme.textTheme.bodyMedium,
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// Read-only excerpt of the file so the user can double-check they picked
  /// the right note. Read errors are shown inline instead of blocking the
  /// deletion: an unreadable file is exactly the kind one wants to remove.
  Widget _preview(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: FutureBuilder<String>(
        future: entryPreview(entry.file, maxChars: kDeletePreviewChars),
        builder: (_, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          final text = snap.hasError
              ? 'Could not read file: ${snap.error}'
              : (snap.data ?? '');
          return SingleChildScrollView(
            child: Text(
              text.isEmpty ? '(empty entry)' : text,
              style: theme.textTheme.bodySmall,
            ),
          );
        },
      ),
    );
  }

  Widget _actions(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        const SizedBox(width: 8),
        FilledButton.icon(
          style: FilledButton.styleFrom(
            backgroundColor: colors.error,
            foregroundColor: colors.onError,
          ),
          onPressed: () => Navigator.of(context).pop(true),
          icon: const Icon(Icons.delete_forever),
          label: const Text('Delete'),
        ),
      ],
    );
  }
}
