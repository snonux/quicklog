import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../services/active_note_store.dart';
import '../services/browser_note_sources.dart';
import '../services/log_service.dart';
import '../services/merged_note_listing.dart';
import '../services/preferences.dart';
import '../services/s3_session_controller.dart';
import '../widgets/s3_degraded_banner.dart';
import 'delete_confirmation_screen.dart';
import 'entry_edit_screen.dart';
import 'first_line_memo.dart';

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
  StorageMode _lastPreferredMode = StorageMode.local;
  bool _s3ListFailed = false;
  bool _wasDegraded = false;
  int _loadGeneration = 0;

  /// Row subtitles of the current load, so a rebuild does not re-read every
  /// visible note; each reload reads them afresh.
  final FirstLineMemo _firstLines = FirstLineMemo();

  /// True while a [_refresh] is in flight; [_sources] may then describe a
  /// mode that no longer applies, so the upload-all action is hidden.
  bool _reloading = false;

  S3SessionController get _session =>
      widget.session ?? S3SessionController.instance;

  ActiveNoteStore get _active =>
      widget.activeStore ?? ActiveNoteStore.instance;

  bool get _showLocation => _sources?.mergeWhenS3Preferred ?? false;

  /// Wording for [BrowserNoteSources.uploadLocalToS3]: dual-write mode keeps
  /// the local copy (Copy), s3-only mode drops it (Move).
  ({String verb, String past}) get _upload =>
      (_sources?.keepLocalCopies ?? false)
      ? (verb: 'Copy', past: 'Copied')
      : (verb: 'Move', past: 'Moved');

  @override
  void initState() {
    super.initState();
    _wasUsingLocalFallback = _session.usesLocalFallback;
    _wasDegraded = _session.isDegraded;
    _lastPreferredMode = _session.preferredMode;
    _session.addListener(_onSessionChanged);
    // Session is loaded once in main(); avoid racing re-load (see HomeScreen).
    _refresh();
  }

  @override
  void dispose() {
    _session.removeListener(_onSessionChanged);
    super.dispose();
  }

  /// Re-list when preferred mode changes or degrade state flips (local
  /// leftovers may appear while S3 is down; S3 rows return when it recovers).
  void _onSessionChanged() {
    if (!mounted) return;
    final usingLocal = _session.usesLocalFallback;
    final mode = _session.preferredMode;
    // Degrade flips matter even when usesLocalFallback cannot change
    // (dual-write mode): the list-failure banner and upload-all visibility
    // track S3 reachability.
    final degraded = _session.isDegraded;
    if (usingLocal == _wasUsingLocalFallback &&
        mode == _lastPreferredMode &&
        degraded == _wasDegraded) {
      return;
    }
    _wasUsingLocalFallback = usingLocal;
    _wasDegraded = degraded;
    _lastPreferredMode = mode;
    _refresh();
  }

  void _refresh() {
    final generation = ++_loadGeneration;
    setState(() {
      _reloading = true;
      _future = _load(generation).whenComplete(() {
        // FutureBuilder rebuilds its child only; setState so AppBar actions
        // (upload all) see the resolved sources / list-failure flag.
        if (mounted && generation == _loadGeneration) {
          setState(() => _reloading = false);
        }
      });
    });
  }

  Future<List<LocatedLogEntry>> _load(int generation) async {
    final dir = await _prefs.directory();
    final sources = await _active.resolveBrowserSources();
    final entries = await sources.list();
    if (generation != _loadGeneration) return entries;
    _dir = dir;
    _sources = sources;
    _wasUsingLocalFallback = _session.usesLocalFallback;
    _wasDegraded = _session.isDegraded;
    _lastPreferredMode = _session.preferredMode;
    _s3ListFailed = sources.s3ListFailed;
    return entries;
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
    final store = sources.entryStore(located);
    final deleteRequested = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => _EntryDetailScreen(
          store: store,
          entry: located.entry,
          location: _showLocation ? located.location : null,
        ),
      ),
    );
    // The viewer may have edited the note even if the delete below fails.
    _firstLines.invalidate(located.id);
    if (!mounted) return;
    if (deleteRequested == true) {
      await _delete(located);
    } else {
      _refresh();
    }
  }

  /// Edits an entry straight from the list. A save re-lists; any other
  /// return re-reads just this row, since a failed save may still have
  /// written one backend ([BrowserNoteSources.update] tries both).
  Future<void> _edit(LocatedLogEntry located) async {
    final sources = _sources;
    if (sources == null) return;
    final saved =
        await editEntry(context, sources.entryStore(located), located.entry);
    if (!mounted) return;
    if (saved) {
      _refresh();
    } else {
      _rereadRow(located.id);
    }
  }

  /// Rebuilds the list so the row of note [id] reads its subtitle again.
  void _rereadRow(String id) {
    _firstLines.invalidate(id);
    setState(() {});
  }

  Future<void> _confirmAndDelete(LocatedLogEntry located) async {
    final sources = _sources;
    if (sources == null) return;
    final confirmed = await confirmEntryDeletion(
      context,
      sources.entryStore(located),
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
      // granted storage scope; keep the entry listed and say why. The note
      // may have been edited in the viewer first, so re-read its subtitle.
      if (mounted) {
        _showSnack('Could not delete $name: $e', isError: true);
        _rereadRow(name);
      }
      return;
    }
    if (!mounted) return;
    _showSnack('Deleted $name');
    _refresh();
  }

  Future<void> _uploadToS3(LocatedLogEntry located) async {
    final sources = _sources;
    if (sources == null) return;
    final upload = _upload;
    try {
      await sources.uploadLocalToS3(located);
    } catch (e) {
      if (mounted) {
        _showSnack(
          'Could not ${upload.verb.toLowerCase()} ${located.id} to S3: $e',
          isError: true,
        );
      }
      return;
    }
    if (!mounted) return;
    _showSnack('${upload.past} ${located.id} to S3');
    _refresh();
  }

  Future<void> _removeLocalCopy(LocatedLogEntry located) async {
    final sources = _sources;
    if (sources == null) return;
    try {
      await sources.removeLocalCopy(located);
    } catch (e) {
      if (mounted) {
        _showSnack(
          'Could not remove local copy of ${located.id}: $e',
          isError: true,
        );
      }
      return;
    }
    if (!mounted) return;
    _showSnack('Removed local copy of ${located.id}');
    _refresh();
  }

  Future<void> _uploadAllLocalToS3() async {
    final sources = _sources;
    if (sources == null || sources.s3 == null) return;
    final upload = _upload;
    // Re-list so we upload whatever is currently local-only, not a stale
    // FutureBuilder snapshot. Abort if LIST failed — otherwise every local
    // id looks local-only and the upload would overwrite unknown remote
    // objects.
    final fresh = await sources.list();
    if (sources.s3ListFailed) {
      if (mounted) {
        setState(() => _s3ListFailed = true);
        _showSnack(
          'Could not list S3 notes; ${upload.verb.toLowerCase()} cancelled.',
          isError: true,
        );
      }
      return;
    }
    final localOnly =
        fresh.where((e) => e.isLocalOnly).toList(growable: false);
    if (localOnly.isEmpty) {
      if (mounted) {
        _showSnack('No local-only notes to ${upload.verb.toLowerCase()}');
      }
      return;
    }
    var done = 0;
    var failed = 0;
    for (final located in localOnly) {
      try {
        await sources.uploadLocalToS3(located);
        done++;
      } catch (_) {
        failed++;
      }
    }
    if (!mounted) return;
    if (failed == 0) {
      _showSnack(
        '${upload.past} $done local note${done == 1 ? '' : 's'} to S3',
      );
    } else {
      _showSnack('${upload.past} $done, failed $failed', isError: true);
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
    // Show whenever S3 merge mode is active, S3 is reachable, and LIST worked;
    // a failed LIST means we cannot tell local-only from both — hide it.
    // Also hidden mid-reload, so a mode flip cannot run the old mode's
    // action (e.g. a Move in dual-write mode) on stale sources.
    final canUploadAll =
        !_reloading && _showLocation && _sources?.s3 != null && !_s3ListFailed;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Entries'),
        actions: [
          if (canUploadAll)
            IconButton(
              tooltip: '${_upload.verb} all local to S3',
              icon: const Icon(Icons.cloud_upload_outlined),
              onPressed: _uploadAllLocalToS3,
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
          if (_s3ListFailed)
            ColoredBox(
              color: Theme.of(context).colorScheme.errorContainer,
              child: ListTile(
                dense: true,
                textColor: Theme.of(context).colorScheme.onErrorContainer,
                title: const Text(
                  'Could not list S3 notes; showing local entries only.',
                ),
                // Invalid saved settings (e.g. endpoint) say what to fix.
                subtitle: switch (_sources?.s3SetupError) {
                  final String reason => Text(
                    'Check the S3 settings in Preferences: $reason',
                  ),
                  null => null,
                },
                trailing: TextButton(
                  onPressed: _refresh,
                  child: const Text('Retry'),
                ),
              ),
            ),
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
          final VoidCallback? secondaryAction;
          final String? secondaryTooltip;
          final IconData? secondaryIcon;
          if (located.isLocalOnly && sources.s3 != null && !_s3ListFailed) {
            // Dual-write mode copies (the row becomes 'both'); s3-only mode
            // moves the note off the device.
            secondaryAction = () => _uploadToS3(located);
            secondaryTooltip = '${_upload.verb} to S3';
            secondaryIcon = Icons.cloud_upload_outlined;
          } else if (located.location == NoteStorageLocation.both &&
              !sources.keepLocalCopies) {
            // Dual-write users keep local copies on purpose; dropping the
            // local side is a durability downgrade, so it is not offered.
            // (Outage leftovers stay local-only and use 'Copy to S3' instead.)
            secondaryAction = () => _removeLocalCopy(located);
            secondaryTooltip = 'Remove local copy';
            secondaryIcon = Icons.folder_off_outlined;
          } else {
            secondaryAction = null;
            secondaryTooltip = null;
            secondaryIcon = null;
          }
          return _EntryTile(
            firstLine: _firstLines.firstLine(
              located,
              sources.storeFor(located),
              generation: _loadGeneration,
            ),
            entry: located.entry,
            location: _showLocation ? located.location : null,
            onTap: () => _open(located),
            onEdit: () => _edit(located),
            // Long-press is kept as the original gesture; the trailing icon
            // makes the same action discoverable without knowing about it.
            onDelete: () => _confirmAndDelete(located),
            onSecondary: secondaryAction,
            secondaryTooltip: secondaryTooltip,
            secondaryIcon: secondaryIcon,
          );
        },
      ),
    );
  }
}

class _EntryTile extends StatelessWidget {
  const _EntryTile({
    required this.firstLine,
    required this.entry,
    required this.onTap,
    required this.onEdit,
    required this.onDelete,
    this.location,
    this.onSecondary,
    this.secondaryTooltip,
    this.secondaryIcon,
  });

  /// Remembered by the browser, so rebuilding the tile does not re-read.
  final Future<String> firstLine;
  final LogEntry entry;
  final NoteStorageLocation? location;
  final VoidCallback onTap;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final VoidCallback? onSecondary;
  final String? secondaryTooltip;
  final IconData? secondaryIcon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      leading: location == null ? null : _LocationBadge(location: location!),
      title: Text(_displayFormat.format(entry.timestamp)),
      subtitle: FutureBuilder<String>(
        future: firstLine,
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
          if (onSecondary != null &&
              secondaryTooltip != null &&
              secondaryIcon != null)
            IconButton(
              tooltip: secondaryTooltip,
              icon: Icon(secondaryIcon),
              onPressed: onSecondary,
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
