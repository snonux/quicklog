import 'package:flutter/material.dart';

import '../services/active_note_store.dart';
import '../services/browser_note_sources.dart';
import '../services/dual_write_s3_repair.dart';
import '../services/log_service.dart';
import '../services/merged_note_listing.dart';
import '../services/preferences.dart';
import '../services/s3_session_controller.dart';
import '../widgets/s3_retry.dart';
import 'delete_confirmation_screen.dart';
import 'entry_detail_screen.dart';
import 'entry_edit_screen.dart';
import 'first_line_memo.dart';

/// Secondary control on one entry row: upload to S3, or drop the local copy.
class EntryBrowserRowAction {
  const EntryBrowserRowAction({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;
}

/// Loads the entry list and runs note actions for the entry browser.
///
/// Not a widget. The screen paints the list and forwards taps here. Listing,
/// session-change refresh, and which row actions are available live here so
/// a change to that policy stays off the tiles.
class EntryBrowserController extends ChangeNotifier {
  EntryBrowserController({
    S3SessionController? session,
    ActiveNoteStore? activeStore,
    PreferencesService? preferences,
  }) : _session = session ?? S3SessionController.instance,
       _active = activeStore ?? ActiveNoteStore.instance,
       _prefs = preferences ?? PreferencesService();

  final S3SessionController _session;
  final ActiveNoteStore _active;
  final PreferencesService _prefs;

  Future<List<LocatedLogEntry>>? _future;
  BrowserNoteSources? _sources;
  String _dir = '';
  bool _wasUsingLocalFallback = false;
  StorageMode _lastPreferredMode = StorageMode.local;
  bool _s3ListFailed = false;
  bool _localListFailed = false;
  bool _wasDegraded = false;
  int _loadGeneration = 0;

  /// Row subtitles of the current load, so a rebuild does not re-read every
  /// visible note; each reload reads them afresh.
  final FirstLineMemo _firstLines = FirstLineMemo();

  /// True while a [refresh] is in flight; [sources] may then describe a
  /// mode that no longer applies, so the upload-all action is hidden.
  bool _reloading = false;
  bool _disposed = false;

  S3SessionController get session => _session;

  Future<List<LocatedLogEntry>>? get future => _future;

  BrowserNoteSources? get sources => _sources;

  String get dir => _dir;

  bool get s3ListFailed => _s3ListFailed;
  bool get localListFailed => _localListFailed;

  bool get showLocation => _sources?.mergeWhenS3Preferred ?? false;

  /// Wording for [BrowserNoteSources.uploadLocalToS3]: dual-write mode keeps
  /// the local copy (Copy), s3-only mode drops it (Move).
  ({String verb, String past}) get upload =>
      (_sources?.keepLocalCopies ?? false)
      ? (verb: 'Copy', past: 'Copied')
      : (verb: 'Move', past: 'Moved');

  /// Show whenever S3 merge mode is active, S3 is reachable, and LIST worked;
  /// a failed LIST means we cannot tell local-only from both — hide it.
  /// Also hidden mid-reload, so a mode flip cannot run the old mode's
  /// action (e.g. a Move in dual-write mode) on stale sources.
  bool get canUploadAll =>
      !_reloading &&
      showLocation &&
      _sources?.s3 != null &&
      !_s3ListFailed &&
      !_localListFailed &&
      _sources?.localListFailed != true;

  /// Subscribes to storage-mode changes and loads the list. Call once from
  /// the screen's [State.initState], after listening to this controller.
  void start() {
    _wasUsingLocalFallback = _session.usesLocalFallback;
    _wasDegraded = _session.isDegraded;
    _lastPreferredMode = _session.preferredMode;
    _session.addListener(_onSessionChanged);
    // S3-only recovery deletes the device copies it moved to the bucket;
    // re-list so no row keeps pointing at a file that is gone.
    _active.localNotesMoved.addListener(_onLocalNotesMoved);
    // Session is loaded once in main(); avoid racing re-load (see HomeScreen).
    refresh();
  }

  @override
  void dispose() {
    _disposed = true;
    _session.removeListener(_onSessionChanged);
    _active.localNotesMoved.removeListener(_onLocalNotesMoved);
    super.dispose();
  }

  void _onLocalNotesMoved() {
    if (!_disposed) refresh();
  }

  /// Re-list when preferred mode changes or degrade state flips (local
  /// leftovers may appear while S3 is down; S3 rows return when it recovers).
  void _onSessionChanged() {
    if (_disposed) return;
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
    refresh();
  }

  void refresh() {
    final generation = ++_loadGeneration;
    _reloading = true;
    _localListFailed = false;
    _future = _load(generation).whenComplete(() {
      // FutureBuilder rebuilds its child only; notify so AppBar actions
      // (upload all) see the resolved sources / list-failure flag.
      if (!_disposed && generation == _loadGeneration) {
        _reloading = false;
        _notify();
      }
    });
    _notify();
  }

  Future<List<LocatedLogEntry>> _load(int generation) async {
    final folder = await _prefs.scopedFolder();
    final dir = folder?.name ?? await _prefs.directory();
    final sources = await _active.resolveBrowserSources();
    // Dual-write only, and not while the degrade window is open: one replay
    // per refresh, so a note edited while S3 was down catches up when it
    // answers. S3-only listings do not enter this branch.
    if (sources.keepLocalCopies &&
        sources.s3 != null &&
        _session.shouldAttemptS3) {
      await sources.replayPendingS3();
    }
    final entries = await sources.list();
    if (generation != _loadGeneration) return entries;
    _dir = dir;
    _sources = sources;
    _wasUsingLocalFallback = _session.usesLocalFallback;
    _wasDegraded = _session.isDegraded;
    _lastPreferredMode = _session.preferredMode;
    _s3ListFailed = sources.s3ListFailed;
    _localListFailed = sources.localListFailed;
    return entries;
  }

  Future<String> firstLineFor(LocatedLogEntry located) {
    return _firstLines.firstLine(
      located,
      _sources!.storeFor(located),
      generation: _loadGeneration,
    );
  }

  String? peekFirstLine(LocatedLogEntry located) {
    return _firstLines.peek(located, generation: _loadGeneration);
  }

  /// Upload or drop-local action for [located], or null when the row should
  /// not offer one.
  EntryBrowserRowAction? secondaryAction(
    BuildContext context,
    LocatedLogEntry located,
  ) {
    final sources = _sources!;
    if (located.isLocalOnly && sources.s3 != null && !_s3ListFailed) {
      // Dual-write mode copies (the row becomes 'both'); s3-only mode
      // moves the note off the device.
      return EntryBrowserRowAction(
        tooltip: '${upload.verb} to S3',
        icon: Icons.cloud_upload_outlined,
        onPressed: () => uploadToS3(context, located),
      );
    }
    if (located.location == NoteStorageLocation.both &&
        !sources.keepLocalCopies) {
      // Dual-write users keep local copies on purpose; dropping the
      // local side is a durability downgrade, so it is not offered.
      // (Outage leftovers stay local-only and use 'Copy to S3' instead.)
      return EntryBrowserRowAction(
        tooltip: 'Remove local copy',
        icon: Icons.folder_off_outlined,
        onPressed: () => removeLocalCopy(context, located),
      );
    }
    return null;
  }

  Future<void> retryS3(BuildContext context) async {
    final result = await retryS3WithFeedback(context, _session);
    if (!context.mounted) return;
    if (result == S3RetryResult.reachable ||
        result == S3RetryResult.armedWithoutProbe) {
      refresh();
    }
  }

  /// Opens the viewer. The viewer cannot delete by itself; it pops with
  /// `true` to request deletion, so all deletions run through [_delete].
  /// A successful delete refreshes the list once. A failed delete follows
  /// [_delete]: a both-location row is re-listed, a single-location row is
  /// re-read (which also shows an edit made in the viewer before the delete
  /// failed). Any other return refreshes as well: the viewer can edit in
  /// place, and a new load is simpler than plumbing an "edited" flag.
  Future<void> open(BuildContext context, LocatedLogEntry located) async {
    final sources = _sources;
    if (sources == null) return;
    final store = sources.entryStore(located);
    final deleteRequested = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => EntryDetailScreen(
          handle: store,
          location: showLocation ? located.location : null,
        ),
      ),
    );
    if (!context.mounted) return;
    if (deleteRequested == true) {
      await _delete(context, located);
    } else {
      refresh();
    }
  }

  /// Edits an entry straight from the list.
  ///
  /// A save (`true`) re-lists. `false` replays a queued dual-write repair
  /// when S3 is up, then re-reads just this row: the user discarded edits,
  /// or a save was attempted and may have written one backend before they
  /// left. `null` does not re-read, because storage was not touched.
  Future<void> edit(BuildContext context, LocatedLogEntry located) async {
    final sources = _sources;
    if (sources == null) return;
    final saved = await editEntry(context, sources.entryStore(located));
    if (!context.mounted) return;
    if (saved == true) {
      refresh();
    } else if (saved == false) {
      // A dual-write save that missed S3 pops false: the device copy is
      // already updated, and this is the chance to replay that one id.
      // A discard of unsaved text hits the same path; replay is a no-op
      // when nothing is queued. Skip a full re-list so other rows are not
      // read again.
      await _replayPendingIfReady();
      await _rereadRow(located);
    }
  }

  /// One dual-write replay when S3 is outside the degrade window. Same gate
  /// as a list refresh, without the list.
  Future<void> _replayPendingIfReady() async {
    final sources = _sources;
    if (sources == null || !sources.keepLocalCopies || sources.s3 == null) {
      return;
    }
    if (!_session.shouldAttemptS3) return;
    await sources.replayPendingS3();
  }

  /// Re-reads the subtitle of [located] without dropping the line already
  /// shown. [NoteStore.read] throws on failure, unlike [NoteStore.firstLine],
  /// which collapses a failure to ''. On success, including an empty note,
  /// the line is [FirstLineMemo.remember]ed for this load and the row
  /// rebuilt. On failure the cached line stays. Does not invalidate first,
  /// and does not re-list.
  Future<void> _rereadRow(LocatedLogEntry located) async {
    final sources = _sources;
    if (sources == null) return;
    final generation = _loadGeneration;
    final String text;
    try {
      text = await sources.storeFor(located).read(located.id);
    } catch (_) {
      return;
    }
    if (_disposed || generation != _loadGeneration) return;
    if (_firstLines.remember(
      located,
      firstLineOf(text),
      generation: generation,
    )) {
      _notify();
    }
  }

  Future<void> confirmAndDelete(
    BuildContext context,
    LocatedLogEntry located,
  ) async {
    final sources = _sources;
    if (sources == null) return;
    final confirmed = await confirmEntryDeletion(
      context,
      sources.entryStore(located),
    );
    if (!confirmed || !context.mounted) return;
    await _delete(context, located);
  }

  /// Performs the already-confirmed deletion and reports the outcome.
  ///
  /// A failed delete of a note listed in both places refreshes the list. The
  /// delete may have removed one backend and left the other, while the row is
  /// still [NoteStorageLocation.both]. A one-row re-read would use
  /// [BrowserNoteSources.storeFor], which in dual-write prefers the local
  /// file, miss it, and blank the subtitle. Re-listing shows the surviving
  /// backend and its real line. A single-location failure re-reads just that
  /// row: the note is still in that one place, and a viewer edit must show up.
  Future<void> _delete(BuildContext context, LocatedLogEntry located) async {
    final sources = _sources;
    if (sources == null) return;
    final name = located.id;
    try {
      await sources.delete(located);
    } on DualWriteS3Pending catch (e) {
      // The on-device file is already gone. Say so, then re-list: the
      // refresh replays the S3 delete when the bucket is up, and otherwise
      // shows the leftover as an S3 row until a later retry. Not an error:
      // the delete the user asked for landed, so S3 being unreachable is at
      // most a warning, not a failure of the delete itself.
      if (!context.mounted) return;
      _showSnack(context, '$e');
      refresh();
      return;
    } catch (e) {
      // Deleting can fail on Android when the directory is outside the app's
      // granted storage scope; keep the entry listed and say why.
      if (!context.mounted) return;
      _showSnack(context, 'Could not delete $name: $e', isError: true);
      if (located.location == NoteStorageLocation.both ||
          sources.keepLocalCopies) {
        // Dual-write: the listing can call a note S3-only while the device
        // file is still there. Refresh replays the upload that delete queued
        // and shows whichever copy survived.
        refresh();
      } else {
        await _rereadRow(located);
      }
      return;
    }
    if (!context.mounted) return;
    _showSnack(context, 'Deleted $name');
    refresh();
  }

  Future<void> uploadToS3(BuildContext context, LocatedLogEntry located) async {
    final sources = _sources;
    if (sources == null) return;
    final labels = upload;
    try {
      await sources.uploadLocalToS3(located);
    } catch (e) {
      if (!context.mounted) return;
      _showSnack(
        context,
        'Could not ${labels.verb.toLowerCase()} ${located.id} to S3: $e',
        isError: true,
      );
      return;
    }
    if (!context.mounted) return;
    _showSnack(context, '${labels.past} ${located.id} to S3');
    refresh();
  }

  Future<void> removeLocalCopy(
    BuildContext context,
    LocatedLogEntry located,
  ) async {
    final sources = _sources;
    if (sources == null) return;
    try {
      await sources.removeLocalCopy(located);
    } catch (e) {
      if (!context.mounted) return;
      _showSnack(
        context,
        'Could not remove local copy of ${located.id}: $e',
        isError: true,
      );
      return;
    }
    if (!context.mounted) return;
    _showSnack(context, 'Removed local copy of ${located.id}');
    refresh();
  }

  Future<void> uploadAllLocalToS3(BuildContext context) async {
    final sources = _sources;
    if (sources == null || sources.s3 == null) return;
    final labels = upload;
    // Re-list so we upload whatever is currently local-only, not a stale
    // FutureBuilder snapshot. Abort if LIST failed — otherwise every local
    // id looks local-only and the upload would overwrite unknown remote
    // objects.
    final fresh = await sources.list();
    if (sources.s3ListFailed) {
      if (!context.mounted) return;
      _s3ListFailed = true;
      _notify();
      _showSnack(
        context,
        'Could not list S3 notes; ${labels.verb.toLowerCase()} cancelled.',
        isError: true,
      );
      return;
    }
    final localOnly = fresh.where((e) => e.isLocalOnly).toList(growable: false);
    if (localOnly.isEmpty) {
      if (!context.mounted) return;
      _showSnack(
        context,
        'No local-only notes to ${labels.verb.toLowerCase()}',
      );
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
    if (!context.mounted) return;
    if (failed == 0) {
      _showSnack(
        context,
        '${labels.past} $done local note${done == 1 ? '' : 's'} to S3',
      );
    } else {
      _showSnack(
        context,
        '${labels.past} $done, failed $failed',
        isError: true,
      );
    }
    refresh();
  }

  void _showSnack(
    BuildContext context,
    String message, {
    bool isError = false,
  }) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? Colors.red : null,
      ),
    );
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }
}
