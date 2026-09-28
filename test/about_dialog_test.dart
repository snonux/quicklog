import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quicklog/screens/home_screen.dart';
import 'package:quicklog/services/app_version.dart';
import 'package:quicklog/services/s3_session_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Serves a fixed `pubspec.yaml` so a test can prove the About dialog reads
/// the version from the bundle instead of a literal in the source. A null
/// [pubspec] makes every load fail, as a missing asset would.
class _FakePubspecBundle extends CachingAssetBundle {
  _FakePubspecBundle(this.pubspec);

  final String? pubspec;

  @override
  Future<ByteData> load(String key) async {
    final content = pubspec;
    if (key != kPubspecAsset || content == null) {
      throw FlutterError('Unable to load asset: $key');
    }
    return ByteData.sublistView(utf8.encode(content));
  }
}

String? _shownVersion(WidgetTester tester) =>
    tester.widget<AboutDialog>(find.byType(AboutDialog)).applicationVersion;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('parsePubspecVersion', () {
    test('returns the semver without the build counter', () {
      expect(parsePubspecVersion('name: x\nversion: 1.2.3+45\n'), '1.2.3');
    });

    test('accepts a version without a build counter or in quotes', () {
      expect(parsePubspecVersion('version: 1.2.3\n'), '1.2.3');
      expect(parsePubspecVersion("version: '1.2.3+4'\n"), '1.2.3');
      expect(parsePubspecVersion('version: "1.2.3" # c\n'), '1.2.3');
    });

    test('ignores indented version keys of nested maps', () {
      expect(
        parsePubspecVersion('deps:\n  version: 9.9.9\nversion: 0.1.0+1\n'),
        '0.1.0',
      );
    });

    test('rejects a pubspec without a version line', () {
      expect(
        () => parsePubspecVersion('name: x\n'),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('About dialog version', () {
    late S3SessionController session;

    setUp(() async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      session = S3SessionController();
      await session.load();
    });

    tearDown(() => session.dispose());

    Future<void> openAbout(WidgetTester tester, {AssetBundle? bundle}) async {
      Widget home = HomeScreen(session: session);
      if (bundle != null) {
        home = DefaultAssetBundle(bundle: bundle, child: home);
      }
      await tester.pumpWidget(MaterialApp(home: home));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('About'));
      await tester.pumpAndSettle();
      expect(find.byType(AboutDialog), findsOneWidget);
    }

    testWidgets('shows the version from the bundle, not a literal', (
      tester,
    ) async {
      await openAbout(
        tester,
        bundle: _FakePubspecBundle('name: quicklog\nversion: 9.8.7+654\n'),
      );
      expect(_shownVersion(tester), '9.8.7');
      expect(find.text('9.8.7'), findsOneWidget);
    });

    // Fail-soft: a broken bundle must not stop About from opening, but the
    // cause has to be reported rather than swallowed.
    for (final (name, pubspec, errorType) in <(String, String?, Type)>[
      ('the asset cannot be loaded', null, FlutterError),
      ('pubspec.yaml has no version line', 'name: quicklog\n', FormatException),
    ]) {
      testWidgets('opens without a version and reports it when $name', (
        tester,
      ) async {
        final reported = <FlutterErrorDetails>[];
        final original = FlutterError.onError;
        FlutterError.onError = reported.add;
        try {
          await openAbout(tester, bundle: _FakePubspecBundle(pubspec));
        } finally {
          FlutterError.onError = original;
        }
        expect(_shownVersion(tester), isNull);
        expect(reported, hasLength(1));
        expect(reported.single.exception.runtimeType, errorType);
      });
    }

    // Drift guard: the version the shipped About dialog shows must be the one
    // in pubspec.yaml on disk. This fails if pubspec.yaml ever stops being
    // bundled as an asset, or if a hard-coded version creeps back in.
    testWidgets('matches the version: line of pubspec.yaml', (tester) async {
      final expected = parsePubspecVersion(
        File('pubspec.yaml').readAsStringSync(),
      );
      await openAbout(tester);
      expect(_shownVersion(tester), expected);
      expect(find.text(expected), findsOneWidget);
    });
  });
}
