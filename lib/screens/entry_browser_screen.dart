import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;

import '../services/log_service.dart';
import '../services/preferences.dart';
import 'delete_confirmation_screen.dart';

final _displayFormat = DateFormat('yyyy-MM-dd HH:mm:ss');

class EntryBrowserScreen extends StatefulWidget {
  const EntryBrowserScreen({super.key});

  @override
  State<EntryBrowserScreen> createState() => _EntryBrowserScreenState();
}

class _EntryBrowserScreenState extends State<EntryBrowserScreen> {
  final PreferencesService _prefs = PreferencesService();
  Future<List<LogEntry>>? _future;
  String _dir = '';

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  void _refresh() {
    setState(() {
      _future = _load();
    });
  }

  Future<List<LogEntry>> _load() async {
    _dir = await _prefs.directory();
    return listEntries(_dir);
  }

  /// Opens the read-only viewer. The viewer cannot delete by itself; it pops
  /// with `true` to request deletion, so all deletions run through
  /// [_confirmAndDelete] here and the list is refreshed exactly once.
  Future<void> _open(LogEntry entry) async {
    final deleteRequested = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => _EntryDetailScreen(entry: entry)),
    );
    if (deleteRequested == true && mounted) await _delete(entry);
  }

  Future<void> _confirmAndDelete(LogEntry entry) async {
    final confirmed = await confirmEntryDeletion(context, entry);
    if (!confirmed || !mounted) return;
    await _delete(entry);
  }

  /// Performs the already-confirmed deletion and reports the outcome.
  Future<void> _delete(LogEntry entry) async {
    final name = p.basename(entry.file.path);
    try {
      await deleteEntry(entry.file);
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
      body: FutureBuilder<List<LogEntry>>(
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
    return RefreshIndicator(
      onRefresh: () async => _refresh(),
      child: ListView.separated(
        itemCount: entries.length,
        separatorBuilder: (_, _) => const Divider(height: 1),
        itemBuilder: (_, i) => _EntryTile(
          entry: entries[i],
          onTap: () => _open(entries[i]),
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
    required this.entry,
    required this.onTap,
    required this.onDelete,
  });

  final LogEntry entry;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: Text(_displayFormat.format(entry.timestamp)),
      subtitle: FutureBuilder<String>(
        future: entryFirstLine(entry.file),
        builder: (_, snap) => Text(
          snap.data ?? '',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      trailing: IconButton(
        tooltip: 'Delete entry',
        icon: const Icon(Icons.delete_outline),
        onPressed: onDelete,
      ),
      onTap: onTap,
      onLongPress: onDelete,
    );
  }
}

/// Read-only viewer for a single entry. It loads the file itself so that the
/// browser does not have to read every entry up front, and it never deletes
/// directly: confirming deletion pops with `true` and the browser does the
/// work, keeping one code path for deletion and error reporting.
class _EntryDetailScreen extends StatelessWidget {
  const _EntryDetailScreen({required this.entry});

  final LogEntry entry;

  Future<void> _requestDelete(BuildContext context) async {
    final confirmed = await confirmEntryDeletion(context, entry);
    if (!confirmed || !context.mounted) return;
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(p.basename(entry.file.path)),
        actions: [
          IconButton(
            tooltip: 'Delete entry',
            icon: const Icon(Icons.delete_outline),
            onPressed: () => _requestDelete(context),
          ),
        ],
      ),
      body: FutureBuilder<String>(
        future: entry.file.readAsString(),
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
