import 'package:flutter/material.dart';

import '../services/active_note_store.dart';
import '../services/merged_note_listing.dart';
import '../services/preferences.dart';
import '../services/s3_session_controller.dart';
import '../widgets/s3_degraded_banner.dart';
import 'entry_browser_controller.dart';
import 'entry_tile.dart';

class EntryBrowserScreen extends StatefulWidget {
  const EntryBrowserScreen({
    super.key,
    this.session,
    this.activeStore,
    this.preferences,
  });

  /// Optional override for tests; defaults to the process-wide session.
  final S3SessionController? session;

  /// Optional override for tests (inject fake S3).
  final ActiveNoteStore? activeStore;

  /// Optional override for tests; defaults to a fresh [PreferencesService].
  /// The running app passes the instance created in `main`.
  final PreferencesService? preferences;

  @override
  State<EntryBrowserScreen> createState() => _EntryBrowserScreenState();
}

class _EntryBrowserScreenState extends State<EntryBrowserScreen> {
  late final EntryBrowserController _browser = EntryBrowserController(
    session: widget.session,
    activeStore: widget.activeStore,
    preferences: widget.preferences,
  );

  @override
  void initState() {
    super.initState();
    _browser.addListener(_onBrowserChanged);
    _browser.start();
  }

  void _onBrowserChanged() {
    if (!mounted) return;
    setState(() {});
  }

  @override
  void dispose() {
    _browser.removeListener(_onBrowserChanged);
    _browser.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final upload = _browser.upload;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Entries'),
        actions: [
          if (_browser.canUploadAll)
            IconButton(
              tooltip: '${upload.verb} all local to S3',
              icon: const Icon(Icons.cloud_upload_outlined),
              onPressed: () => _browser.uploadAllLocalToS3(context),
            ),
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: _browser.refresh,
          ),
        ],
      ),
      body: Column(
        children: [
          // The setup-error banner below (invalid saved settings) is the
          // one message that says what to fix, so while it is up the
          // session-wide degrade banner would only repeat the outage.
          if (_browser.sources?.s3SetupError == null)
            S3DegradedBanner(
              session: _browser.session,
              onRetry: () => _browser.retryS3(context),
            ),
          // While the session is degraded, S3DegradedBanner above already
          // reports the outage as the single warning; a second, error-styled
          // banner for the same unreachable bucket would double the message.
          // A setup error (invalid saved settings) still shows even while
          // degraded: it says what to fix, which the degrade banner cannot.
          if (_browser.s3ListFailed &&
              (!_browser.session.isDegraded ||
                  _browser.sources?.s3SetupError != null))
            ColoredBox(
              color: Theme.of(context).colorScheme.errorContainer,
              child: ListTile(
                dense: true,
                textColor: Theme.of(context).colorScheme.onErrorContainer,
                title: const Text(
                  'Could not list S3 notes; showing local entries only.',
                ),
                // Invalid saved settings (e.g. endpoint) say what to fix.
                subtitle: switch (_browser.sources?.s3SetupError) {
                  final String reason => Text(
                    'Check the S3 settings in Preferences: $reason',
                  ),
                  null => null,
                },
                trailing: TextButton(
                  onPressed: _browser.refresh,
                  child: const Text('Retry'),
                ),
              ),
            ),
          if (_browser.localListFailed)
            ColoredBox(
              color: Theme.of(context).colorScheme.errorContainer,
              child: ListTile(
                dense: true,
                textColor: Theme.of(context).colorScheme.onErrorContainer,
                title: const Text(
                  'Could not list the selected local folder; showing S3 entries only.',
                ),
                subtitle: const Text(
                  'Check folder access in Preferences, then refresh.',
                ),
                trailing: TextButton(
                  onPressed: _browser.refresh,
                  child: const Text('Retry'),
                ),
              ),
            ),
          Expanded(
            child: FutureBuilder<List<LocatedLogEntry>>(
              future: _browser.future,
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
    final message = _browser.showLocation
        ? 'No entries in local storage or S3'
        : 'No entries in ${_browser.dir}';
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(message, textAlign: TextAlign.center),
      ),
    );
  }

  Widget _entryList(List<LocatedLogEntry> entries) {
    return RefreshIndicator(
      onRefresh: () async => _browser.refresh(),
      child: ListView.separated(
        itemCount: entries.length,
        separatorBuilder: (_, _) => const Divider(height: 1),
        itemBuilder: (_, i) {
          final located = entries[i];
          final secondary = _browser.secondaryAction(context, located);
          return EntryTile(
            firstLine: _browser.firstLineFor(located),
            initialLine: _browser.peekFirstLine(located),
            entry: located.entry,
            location: _browser.showLocation ? located.location : null,
            onTap: () => _browser.open(context, located),
            onEdit: () => _browser.edit(context, located),
            // Long-press is kept as the original gesture; the trailing icon
            // makes the same action discoverable without knowing about it.
            onDelete: () => _browser.confirmAndDelete(context, located),
            onSecondary: secondary?.onPressed,
            secondaryTooltip: secondary?.tooltip,
            secondaryIcon: secondary?.icon,
          );
        },
      ),
    );
  }
}
