import 'package:flutter/material.dart';

import '../services/s3_session_controller.dart';

/// Runs [S3SessionController.retryS3] and shows the snackbar the home screen
/// and the entry browser used to build separately.
///
/// Returns the outcome so a caller can do something extra when S3 is back
/// (the browser re-lists). Returns null when the retry threw — the error
/// snackbar is already up — or the widget was unmounted before a message
/// could be shown.
///
/// [S3RetryResult.armedWithoutProbe] means no probe ran. If a probe was
/// attached while the degrade window was clearing, say reachable; otherwise
/// do not claim a connectivity check that never happened.
Future<S3RetryResult?> retryS3WithFeedback(
  BuildContext context,
  S3SessionController session,
) async {
  try {
    final result = await session.retryS3();
    if (!context.mounted) return null;
    final message = switch (result) {
      S3RetryResult.reachable => 'S3 reachable again.',
      S3RetryResult.armedWithoutProbe =>
        session.probe == null
            ? 'S3 retry armed (no connectivity check yet).'
            : 'S3 reachable again.',
      S3RetryResult.unavailable => 'S3 still unavailable.',
      S3RetryResult.ignored => 'S3 retry not applicable.',
    };
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
    return result;
  } catch (e) {
    if (!context.mounted) return null;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Retry failed: $e'), backgroundColor: Colors.red),
    );
    return null;
  }
}
