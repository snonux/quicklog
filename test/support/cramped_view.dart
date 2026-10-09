import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Font scale of the cramped setup: 1.3, the largest step of Android's
/// classic font-size setting.
const crampedTextScale = 1.3;

/// Shrinks the test view so a button row has almost no room to spare, and
/// restores it when the test ends.
///
/// 420 logical pixels is not a narrow phone on a real device, but the test
/// font draws every glyph as a full square, so the two action buttons alone
/// take most of that at [crampedTextScale]. They still fit; what is left
/// over (some tens of pixels) is far less than a long character count needs,
/// which is the situation the counter has to survive. The tests using this
/// assert that shortfall themselves, so a layout change that makes the view
/// roomy fails them instead of letting them pass for nothing.
void useCrampedView(WidgetTester tester) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(420, 800);
  addTearDown(tester.view.reset);
}

/// `MaterialApp.builder` that applies [crampedTextScale] to the whole app.
Widget crampedTextScaleBuilder(BuildContext context, Widget? child) {
  return MediaQuery(
    data: MediaQuery.of(
      context,
    ).copyWith(textScaler: const TextScaler.linear(crampedTextScale)),
    child: child!,
  );
}

/// Asserts the character counter showing [text] has room: it is drawn at its
/// full size, at the far end of the slot the row leaves it, with spare room
/// before it. This is what the counter looks like on every ordinary screen.
/// The far end is the right edge, or the left one when [direction] is
/// right-to-left.
void expectCounterAtRowEndUnshrunk(
  WidgetTester tester,
  String text, {
  TextDirection direction = TextDirection.ltr,
}) {
  final counter = find.text(text);
  final slot = tester.getRect(
    find.ancestor(of: counter, matching: find.byType(FittedBox)),
  );
  final drawn = tester.getRect(counter);
  expect(drawn.size, tester.getSize(counter));
  if (direction == TextDirection.rtl) {
    expect(drawn.left, closeTo(slot.left, 0.5));
    expect(drawn.right, lessThan(slot.right));
  } else {
    expect(drawn.right, closeTo(slot.right, 0.5));
    expect(drawn.left, greaterThan(slot.left));
  }
}

/// `MaterialApp.builder` that lays the whole app out right-to-left.
Widget rightToLeftBuilder(BuildContext context, Widget? child) {
  return Directionality(textDirection: TextDirection.rtl, child: child!);
}
