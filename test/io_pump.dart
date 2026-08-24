import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Drop-in replacement for `pumpAndSettle` for widgets that read real files.
///
/// The entry browser, the detail view and the delete confirmation screen all
/// load their content with `dart:io`. Those futures never complete inside the
/// fake-async zone that drives the normal pump loop, so `pumpAndSettle` spins
/// on the loading indicator until it times out. Alternating a normal pump
/// (which advances route and indicator animations on the fake clock) with a
/// short real delay inside [WidgetTester.runAsync] (which lets the real event
/// loop deliver the I/O results) settles both.
Future<void> pumpWithIo(WidgetTester tester, {int rounds = 12}) async {
  for (var i = 0; i < rounds; i++) {
    await tester.pump(const Duration(milliseconds: 50));
    await tester.runAsync(() => Future<void>.delayed(
          const Duration(milliseconds: 5),
        ));
  }
}

/// Real-filesystem `File.exists()` for use inside a widget test body.
///
/// Same reason as [pumpWithIo]: awaiting a `dart:io` future directly in a
/// test body hangs, because the body runs on the fake clock. Routing it
/// through [WidgetTester.runAsync] gives the real event loop a chance to
/// deliver the answer.
Future<bool> fileExists(WidgetTester tester, File file) async {
  return await tester.runAsync(() => file.exists()) ?? false;
}
