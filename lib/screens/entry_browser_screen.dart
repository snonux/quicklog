import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../services/active_note_store.dart';
import '../services/log_service.dart';
import '../services/merged_note_listing.dart';
import '../services/preferences.dart';
import '../services/s3_session_controller.dart';
import '../widgets/s3_degraded_banner.dart';
import 'delete_confirmation_screen.dart';
import 'entry_edit_screen.dart';

final _displayFormat = DateFormat('yyyy-MM-dd HH:mm:ss');

class EntryBrowserScreen extends StatefulWidget {
  const EntryBrowserScreen({super.key, this.session, this.activeStore});

  /// Optional override for tests; defaults to the process-wide session.
  final S3SessionController? session;

  /// Optional override for tests (inject fake S3).
  final ActiveNoteStore? activeStore;

  @override
  State<EntryBrowserScreen> createState() => _EntryBrowserScreenState();
}

class _EntryBrowserScreenState extends State<EntryBrowserScreen> {
  final PreferencesService _prefs = PreferencesService();
  Future<List<LocatedLogEntry>>? _future;
  BrowserNoteSources? _sources;
  String _dir = '';
  bool _wasUsingLocalFallback = false;

  S3SessionController get _session =>
      widget.session ?? S3SessionController.instance;

  ActiveNoteStore get _active =>
      widget.activeStore ?? ActiveNoteStore.instance;

  bool get _showLocation => _sources?.mergeWhenS3Preferred ?? false;

  @override
  void initState() {
    super.initState();
    _wasUsingLocalFallback = _session.usesLocalFallback;
    _session.addListener(_onSessionChanged);
    // Session is loaded once in main(); avoid racing re-load (see HomeScreen).
    _refresh();
  }

  @override
  void dispose() {
    _session.removeListener(_onSessionChanged);
    super.dispose();
  }

  /// When the session flips to/from local fallback, drop the cached sources and
  /// re-resolve so we do not keep calling a stale [S3NoteStore].
  void _onSessionChanged() {
    if (!mounted) return;
    final usingLocal = _session.usesLocalFallback;
    if (usingLocal == _wasUsingLocalFallback) return;
    _wasUsingLocalFallback = usingLocal;
    _refresh();
  }

  void _refresh() {
    setState(() {
      _future = _load().then((entries) {
        // FutureBuilder rebuilds its child only; setState so AppBar actions
        // (Move all) see the resolved sources.
        if (mounted) setState(() {});
        return entries;
      });
    });
  }

  Future<List<LocatedLogEntry>> _load() async {
    _dir = await _prefs.directory();
    _sources = await _active.resolveBrowserSources();
    _wasUsingLocalFallback = _session.usesLocalFallback;
    return _sources!.list();
  }

  Future<void> _retryS3() async {
    try {
      final result = await _session.retryS3();
      if (!mounted) return;
      final message = switch (result) {
        S3RetryResult.reachable => 'S3 reachable again.',
        S3RetryResult.armedWithoutProbe => _session.probe == null
            ? 'S3 retry armed (no connectivity check yet).'
            : 'S3 reachable again.',
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
  Future<void> _open(LocatedLogEntry located) async {
    final sources = _sources;
    if (sources == null) return;
    final store = sources.storeFor(located);
    final deleteRequested = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => _EntryDetailScreen(
          store: store,
          entry: located.entry,
          location: _showLocation ? located.location : null,
        ),
      ),
    );
    if (!mounted) return;
    if (deleteRequested == true) {
      await _delete(located);
    } else {
      _refresh();
    }
  }

  /// Edits an entry straight from the list. Only a save changes the note, so
  /// the listing is re-read only then.
  Future<void> _edit(LocatedLogEntry located) async {
    final sources = _sources;
    if (sources == null) return;
    final saved = await editEntry(context, sources.storeFor(located), located.entry);
    if (saved && mounted) _refresh();
  }

  Future<void> _confirmAndDelete(LocatedLogEntry located) async {
    final sources = _sources;
    if (sources == null) return;
    final confirmed = await confirmEntryDeletion(
      context,
      sources.storeFor(located),
      located.entry,
    );
    if (!confirmed || !mounted) return;
    await _delete(located);
  }

  /// Performs the already-confirmed deletion and reports the outcome.
  Future<void> _delete(LocatedLogEntry located) async {
    final sources = _sources;
    if (sources == null) return;
    final name = located.id;
    try {
      await sources.delete(located);
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

  Future<void> _moveToS3(LocatedLogEntry located) async {
    final sources = _sources;
    if (sources == null) return;
    try {
      await sources.moveLocalToS3(located);
    } catch (e) {
      if (mounted) {
        _showSnack('Could not move ${located.id} to S3: $e', isError: true);
      }
      return;
    }
    if (!mounted) return;
    _showSnack('Moved ${located.id} to S3');
    _refresh();
  }

  Future<void> _moveAllLocalToS3() async {
    final sources = _sources;
    if (sources == null || sources.s3 == null) return;
    // Re-list so we move whatever is currently local-only, not a stale
    // FutureBuilder snapshot.
    final fresh = await sources.list();
    final localOnly =
        fresh.where((e) => e.isLocalOnly).toList(growable: false);
    if (localOnly.isEmpty) {
      if (mounted) _showSnack('No local-only notes to move');
      return;
    }
    var moved = 0;
    var failed = 0;
    for (final located in localOnly) {
      try {
        await sources.moveLocalToS3(located);
        moved++;
      } catch (_) {
        failed++;
      }
    }
    if (!mounted) return;
    if (failed == 0) {
      _showSnack('Moved $moved local note${moved == 1 ? '' : 's'} to S3');
    } else {
      _showSnack(
        'Moved $moved, failed $failed',
        isError: true,
      );
    }
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
    // Show whenever S3 merge mode is active and S3 is reachable; the action
    // re-lists and no-ops with a snackbar when nothing is local-only.
    final canMoveAll = _showLocation && _sources?.s3 != null;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Entries'),
        actions: [
          if (canMoveAll)
            IconButton(
              tooltip: 'Move all local to S3',
              icon: const Icon(Icons.cloud_upload_outlined),
              onPressed: _moveAllLocalToS3,
            ),
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
            child: FutureBuilder<List<LocatedLogEntry>>(
              future: _future,
              builder: (ctx, snap) {
                if (snap.connectionState != ConnectionState.done) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (snap.hasError) {
                  return Center(child: Text('Error: ${snap.error}'));
                }
                final entries = snap.data ?? const <LocatedLogEntry>[];
                return entries.isEmpty ? _emptyState() : _entryList(entries);
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _emptyState() {
    final message = _showLocation
        ? 'No entries in local storage or S3'
        : 'No entries in $_dir';
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(message, textAlign: TextAlign.center),
      ),
    );
  }

  Widget _entryList(List<LocatedLogEntry> entries) {
    final sources = _sources!;
    return RefreshIndicator(
      onRefresh: () async => _refresh(),
      child: ListView.separated(
        itemCount: entries.length,
        separatorBuilder: (_, _) => const Divider(height: 1),
        itemBuilder: (_, i) {
          final located = entries[i];
          return _EntryTile(
            store: sources.storeFor(located),
            entry: located.entry,
            location: _showLocation ? located.location : null,
            onTap: () => _open(located),
            onEdit: () => _edit(located),
            // Long-press is kept as the original gesture; the trailing icon
            // makes the same action discoverable without knowing about it.
            onDelete: () => _confirmAndDelete(located),
            onMoveToS3: located.isLocalOnly && sources.s3 != null
                ? () => _moveToS3(located)
                : null,
          );
        },
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
    this.location,
    this.onMoveToS3,
  });

  final NoteStore store;
  final LogEntry entry;
  final NoteStorageLocation? location;
  final VoidCallback onTap;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final VoidCallback? onMoveToS3;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      leading: location == null ? null : _LocationBadge(location: location!),
      title: Text(_displayFormat.format(entry.timestamp)),
      subtitle: FutureBuilder<String>(
        future: store.firstLine(entry.id),
        builder: (_, snap) {
          final line = snap.data ?? '';
          final label = location == null ? null : _locationLabel(location!);
          return Text(
            label == null ? line : '$label · $line',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyMedium,
          );
        },
      ),
      // Edit and delete sit side by side so both are reachable without
      // opening the entry first; tapping the row still just views it.
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (onMoveToS3 != null)
            IconButton(
              tooltip: 'Move to S3',
              icon: const Icon(Icons.cloud_upload_outlined),
              onPressed: onMoveToS3,
            ),
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

class _LocationBadge extends StatelessWidget {
  const _LocationBadge({required this.location});

  final NoteStorageLocation location;

  @override
  Widget build(BuildContext context) {
    final (icon, tooltip) = switch (location) {
      NoteStorageLocation.local => (Icons.folder_outlined, 'Local'),
      NoteStorageLocation.s3 => (Icons.cloud_outlined, 'S3'),
      NoteStorageLocation.both => (Icons.cloud_sync_outlined, 'Local + S3'),
    };
    return Tooltip(
      message: tooltip,
      child: Icon(icon),
    );
  }
}

String _locationLabel(NoteStorageLocation location) => switch (location) {
      NoteStorageLocation.local => 'Local',
      NoteStorageLocation.s3 => 'S3',
      NoteStorageLocation.both => 'Local + S3',
    };

/// Viewer for a single entry. It loads the note itself so that the browser
/// does not have to read every entry up front, and it never deletes directly:
/// confirming deletion pops with `true` and the browser does the work,
/// keeping one code path for deletion and error reporting. Editing is pushed
/// on top of it, and the viewer re-reads afterwards so what is on screen
/// matches what is stored.
class _EntryDetailScreen extends StatefulWidget {
  const _EntryDetailScreen({
    required this.store,
    required this.entry,
    this.location,
  });

  final NoteStore store;
  final LogEntry entry;
  final NoteStorageLocation? location;

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
    final location = widget.location;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.entry.id),
        actions: [
          if (location != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Center(
                child: Text(
                  _locationLabel(location),
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
