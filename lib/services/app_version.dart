import 'package:flutter/services.dart';

/// Asset key of the bundled `pubspec.yaml`, declared under `flutter: assets:`.
///
/// The `version:` line of `pubspec.yaml` is the single source of truth for the
/// app version (see README "Releases"). Android derives `versionName` and
/// `versionCode` from it at build time; bundling the file as an asset lets the
/// Dart side read the very same line at runtime, so the About dialog can never
/// drift from a release bump. This avoids a native plugin such as
/// package_info_plus, which would add Android code to the F-Droid
/// reproducible build for a single string.
const String kPubspecAsset = 'pubspec.yaml';

/// Returns the semantic version (`X.Y.Z`, without the `+buildNumber` counter)
/// from the top-level `version:` line of [pubspec].
///
/// The build number is dropped because the release tag and Android's
/// `versionName` are the semver alone. Throws [FormatException] when no
/// usable `version:` line exists.
String parsePubspecVersion(String pubspec) {
  final match = RegExp(
    r'''^version:[ \t]*['"]?([^'"+\s#]+)''',
    multiLine: true,
  ).firstMatch(pubspec);
  if (match == null) {
    throw const FormatException('pubspec.yaml has no version: line');
  }
  return match.group(1)!;
}

/// Loads the app version from the bundled `pubspec.yaml` in [bundle].
///
/// Pass `DefaultAssetBundle.of(context)` so widget tests can substitute a
/// bundle; [rootBundle] caches the string, so repeated calls are cheap.
Future<String> loadAppVersion(AssetBundle bundle) async =>
    parsePubspecVersion(await bundle.loadString(kPubspecAsset));
