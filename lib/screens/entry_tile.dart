import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../services/log_service.dart';
import '../services/merged_note_listing.dart';

final _displayFormat = DateFormat('yyyy-MM-dd HH:mm:ss');

/// Short place name shown on a row subtitle and the entry viewer.
String noteLocationLabel(NoteStorageLocation location) => switch (location) {
  NoteStorageLocation.local => 'Local',
  NoteStorageLocation.s3 => 'S3',
  NoteStorageLocation.both => 'Local + S3',
};

/// One row in the entry list: timestamp, first line, and the row actions.
class EntryTile extends StatelessWidget {
  const EntryTile({
    super.key,
    required this.firstLine,
    required this.entry,
    required this.onTap,
    required this.onEdit,
    required this.onDelete,
    this.initialLine,
    this.location,
    this.onSecondary,
    this.secondaryTooltip,
    this.secondaryIcon,
  });

  /// Remembered by the browser, so rebuilding the tile does not re-read.
  final Future<String> firstLine;

  /// Line already resolved for this load. Null while the read is in flight,
  /// so a new row stays blank until [firstLine] completes; a row that scrolls
  /// back paints [initialLine] on the first frame.
  final String? initialLine;
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
        initialData: initialLine,
        builder: (_, snap) {
          final line = snap.data ?? '';
          final label = location == null ? null : noteLocationLabel(location!);
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
