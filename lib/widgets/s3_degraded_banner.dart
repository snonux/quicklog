import 'package:flutter/material.dart';

import '../services/s3_session_controller.dart';

/// Banner shown on home / browser while preferred storage is S3 but the
/// session is degraded to local after a failure.
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
                    'Using local (S3 unavailable). Retry or wait until the '
                    'degrade window ends.',
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
