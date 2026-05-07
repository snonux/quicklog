import 'dart:io';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;

import '../services/log_service.dart';
import '../services/preferences.dart';

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

  Future<void> _open(LogEntry entry) async {
    final content = await entry.file.readAsString();
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => _EntryDetailScreen(entry: entry, content: content),
      ),
    );
  }

  Future<void> _confirmDelete(LogEntry entry) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete entry?'),
        content: Text(p.basename(entry.file.path)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok == true) {
      await deleteEntry(entry.file);
      _refresh();
    }
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
          final entries = snap.data ?? const [];
          if (entries.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  'No entries in $_dir',
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }
          return RefreshIndicator(
            onRefresh: () async => _refresh(),
            child: ListView.separated(
              itemCount: entries.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (_, i) => _EntryTile(
                entry: entries[i],
                onTap: () => _open(entries[i]),
                onLongPress: () => _confirmDelete(entries[i]),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _EntryTile extends StatelessWidget {
  const _EntryTile({required this.entry, required this.onTap, required this.onLongPress});
  final LogEntry entry;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: Text(_displayFormat.format(entry.timestamp)),
      subtitle: FutureBuilder<String>(
        future: _firstLine(entry.file),
        builder: (_, snap) => Text(
          snap.data ?? '',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      onTap: onTap,
      onLongPress: onLongPress,
    );
  }

  Future<String> _firstLine(File f) async {
    try {
      final content = await f.readAsString();
      final i = content.indexOf('\n');
      return i < 0 ? content : content.substring(0, i);
    } catch (_) {
      return '';
    }
  }
}

class _EntryDetailScreen extends StatelessWidget {
  const _EntryDetailScreen({required this.entry, required this.content});
  final LogEntry entry;
  final String content;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(p.basename(entry.file.path))),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(12),
        child: SelectableText(content),
      ),
    );
  }
}
