import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../services/log_service.dart';
import '../services/preferences.dart';
import '../services/s3_session_controller.dart';
import '../widgets/s3_degraded_banner.dart';
import 'delete_confirmation_screen.dart';
import 'entry_edit_screen.dart';

final _displayFormat = DateFormat('yyyy-MM-dd HH:mm:ss');

class EntryBrowserScreen extends StatefulWidget {
  const EntryBrowserScreen({super.key, this.session});

  /// Optional override for tests; defaults to the process-wide session.
  final S3SessionController? session;

  @override
  State<EntryBrowserScreen> createState() => _EntryBrowserScreenState();
}

class _EntryBrowserScreenState extends State<EntryBrowserScreen> {
  final PreferencesService _prefs = PreferencesService();
  Future<List<LogEntry>>? _future;
  NoteStore? _store;
  String _dir = '';

  S3SessionController get _session =>
      widget.session ?? S3SessionController.instance;

  @override
  void initState() {
    super.initState();
    // Session is loaded once in main(); avoid racing re-load (see HomeScreen).
    _refresh();
  }

  void _refresh() {
    setState(() {
      _future = _load();
    });
  }

  Future<List<LogEntry>> _load() async {
    _dir = await _prefs.directory();
    // S3NoteStore lands later; local fallback still applies when degraded.
    _store = _session.resolveStore(local: () => LocalNoteStore(_dir));
    return _store!.list();
  }

  Future<void> _retryS3() async {
    try {
      final result = await _session.retryS3();
      if (!mounted) return;
      final message = switch (result) {
        S3RetryResult.reachable => 'S3 reachable again.',
        S3RetryResult.armedWithoutProbe =>
          'S3 retry armed (no connectivity check yet).',
        S3RetryResult.unavailable => 'S3 still unavailable.',
        S3RetryResult.ignored => 'S3 retry not applicable.',
      };
      _showSnack(message);
      if (result == S3RetryResult.reachable ||
          result == S3RetryResult.armedWithoutProbe) {
        _refresh();
      }
    } catch (e) {
      if (!mounted) return;
      _showSnack('Retry failed: $e', isError: true);
    }
  }

  /// Opens the viewer. The viewer cannot delete by itself; it pops with
  /// `true` to request deletion, so all deletions run through [_delete] here
  /// and the list is refreshed exactly once. It can edit in place, though,
  /// which changes the subtitle previews, so any other return re-lists the
  /// directory -- cheap, and simpler than plumbing an "edited" flag back.
  Future<void> _open(LogEntry entry) async {
    final store = _store;
    if (store == null) return;
    final deleteRequested = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => _EntryDetailScreen(store: store, entry: entry),
      ),
    );
    if (!mounted) return;
    if (deleteRequested == true) {
      await _delete(entry);
    } else {
      _refresh();
    }
  }

  /// Edits an entry straight from the list. Only a save changes the note, so
  /// the listing is re-read only then.
  Future<void> _edit(LogEntry entry) async {
    final store = _store;
    if (store == null) return;
    final saved = await editEntry(context, store, entry);
    if (saved && mounted) _refresh();
  }

  Future<void> _confirmAndDelete(LogEntry entry) async {
    final store = _store;
    if (store == null) return;
    final confirmed = await confirmEntryDeletion(context, store, entry);
    if (!confirmed || !mounted) return;
    await _delete(entry);
  }

  /// Performs the already-confirmed deletion and reports the outcome.
  Future<void> _delete(LogEntry entry) async {
    final store = _store;
    if (store == null) return;
    final name = entry.id;
    try {
      await store.delete(entry.id);
    } catch (e) {
      // Deleting can fail on Android when the directory is outside the app's
      // granted storage scope; keep the entry listed and say why.
      if (mounted) _showSnack('Could not delete $name: $e', isError: true);
      return;
    }
    if (!mounted) return;
    _showSnack('Deleted $name');
    _refresh();
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
    return Scaffold(
      appBar: AppBar(
        title: const Text('Entries'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: _refresh,
          ),
        ],
      ),
      body: Column(
        children: [
          S3DegradedBanner(session: _session, onRetry: _retryS3),
          Expanded(
            child: FutureBuilder<List<LogEntry>>(
              future: _future,
              builder: (ctx, snap) {
                if (snap.connectionState != ConnectionState.done) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (snap.hasError) {
                  return Center(child: Text('Error: ${snap.error}'));
                }
                final entries = snap.data ?? const <LogEntry>[];
                return entries.isEmpty ? _emptyState() : _entryList(entries);
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _emptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text('No entries in $_dir', textAlign: TextAlign.center),
      ),
    );
  }

  Widget _entryList(List<LogEntry> entries) {
    final store = _store!;
    return RefreshIndicator(
      onRefresh: () async => _refresh(),
      child: ListView.separated(
        itemCount: entries.length,
        separatorBuilder: (_, _) => const Divider(height: 1),
        itemBuilder: (_, i) => _EntryTile(
          store: store,
          entry: entries[i],
          onTap: () => _open(entries[i]),
          onEdit: () => _edit(entries[i]),
          // Long-press is kept as the original gesture; the trailing icon
          // makes the same action discoverable without knowing about it.
          onDelete: () => _confirmAndDelete(entries[i]),
        ),
      ),
    );
  }
}

class _EntryTile extends StatelessWidget {
  const _EntryTile({
    required this.store,
    required this.entry,
    required this.onTap,
    required this.onEdit,
    required this.onDelete,
  });

  final NoteStore store;
  final LogEntry entry;
  final VoidCallback onTap;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: Text(_displayFormat.format(entry.timestamp)),
      subtitle: FutureBuilder<String>(
        future: store.firstLine(entry.id),
        builder: (_, snap) => Text(
          snap.data ?? '',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      // Edit and delete sit side by side so both are reachable without
      // opening the entry first; tapping the row still just views it.
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: 'Edit entry',
            icon: const Icon(Icons.edit_outlined),
            onPressed: onEdit,
          ),
          IconButton(
            tooltip: 'Delete entry',
            icon: const Icon(Icons.delete_outline),
            onPressed: onDelete,
          ),
        ],
      ),
      onTap: onTap,
      onLongPress: onDelete,
    );
  }
}

/// Viewer for a single entry. It loads the note itself so that the browser
/// does not have to read every entry up front, and it never deletes directly:
/// confirming deletion pops with `true` and the browser does the work,
/// keeping one code path for deletion and error reporting. Editing is pushed
/// on top of it, and the viewer re-reads afterwards so what is on screen
/// matches what is stored.
class _EntryDetailScreen extends StatefulWidget {
  const _EntryDetailScreen({required this.store, required this.entry});

  final NoteStore store;
  final LogEntry entry;

  @override
  State<_EntryDetailScreen> createState() => _EntryDetailScreenState();
}

class _EntryDetailScreenState extends State<_EntryDetailScreen> {
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
      _content = widget.store.read(widget.entry.id);
    });
  }

  Future<void> _edit() async {
    final saved = await editEntry(context, widget.store, widget.entry);
    if (saved && mounted) _reload();
  }

  Future<void> _requestDelete() async {
    final confirmed =
        await confirmEntryDeletion(context, widget.store, widget.entry);
    if (!confirmed || !mounted) return;
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.entry.id),
        actions: [
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
