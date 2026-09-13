import 'package:flutter/material.dart';

import '../services/preferences.dart';
import '../services/s3_session_controller.dart';

/// Banner shown on home / browser while preferred storage uses S3 (s3-only
/// or dual write) but the session is degraded after a failure.
class S3DegradedBanner extends StatelessWidget {
  const S3DegradedBanner({
    super.key,
    required this.session,
    this.onRetry,
  });

  final S3SessionController session;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: session,
      builder: (context, _) {
        if (!session.isDegraded) return const SizedBox.shrink();
        final scheme = Theme.of(context).colorScheme;
        // In dual write local is the permanent primary, not a fallback —
        // only the S3 mirror is paused, so say that.
        final dual = session.preferredMode == StorageMode.both;
        return Material(
          color: scheme.tertiaryContainer,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                Icon(Icons.cloud_off, color: scheme.onTertiaryContainer),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    dual
                        ? 'S3 unavailable — notes are still being saved '
                            'locally. Retry S3 or wait until the degrade '
                            'window ends.'
                        : 'Using local (S3 unavailable). Retry or wait until '
                            'the degrade window ends.',
                    style: TextStyle(color: scheme.onTertiaryContainer),
                  ),
                ),
                TextButton(
                  onPressed: onRetry,
                  child: const Text('Retry S3'),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
