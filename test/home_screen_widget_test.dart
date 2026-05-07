import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quicklog/screens/home_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('character counter updates as user types', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await tester.pumpWidget(const MaterialApp(home: HomeScreen()));
    await tester.pumpAndSettle();

    expect(find.text('0 chars'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'hello');
    await tester.pump();
    expect(find.text('5 chars'), findsOneWidget);
  });

  testWidgets('Clear button empties the input', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await tester.pumpWidget(const MaterialApp(home: HomeScreen()));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'something');
    await tester.pump();
    expect(find.text('9 chars'), findsOneWidget);

    await tester.tap(find.text('Clear'));
    await tester.pump();
    expect(find.text('0 chars'), findsOneWidget);
  });

  testWidgets('Log text button is rendered and enabled', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await tester.pumpWidget(const MaterialApp(home: HomeScreen()));
    await tester.pumpAndSettle();

    final btn = find.widgetWithText(FilledButton, 'Log text');
    expect(btn, findsOneWidget);
    expect(tester.widget<FilledButton>(btn).enabled, isTrue);
  });
}
