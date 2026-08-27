import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guards the invariants the F-Droid packaging depends on. See the comment above
/// `version:` in pubspec.yaml and docs/fdroid-submission.md: `--split-per-abi`
/// makes Flutter stamp `buildNumber + 1000/2000/4000` into the per-ABI APKs, so a
/// build number that reaches 1000 lets two different releases collide on the same
/// APK versionCode -- which F-Droid rejects and Android reads as the same build.
void main() {
  final versionLine = File('pubspec.yaml')
      .readAsLinesSync()
      .firstWhere((line) => line.startsWith('version:'));
  final match =
      RegExp(r'^version:\s*(\d+\.\d+\.\d+)\+(\d+)$').firstMatch(versionLine);

  test('pubspec version line is <semver>+<buildNumber>', () {
    expect(
      match,
      isNotNull,
      reason: 'F-Droid parses this line with '
          r'`version:\s.+\+(\d+)` and `version:\s(.+)\+`; '
          'anything else silently breaks its update check. Got: $versionLine',
    );
  });

  test('build number stays below 1000', () {
    final buildNumber = int.parse(match!.group(2)!);
    expect(buildNumber, greaterThan(0));
    expect(
      buildNumber,
      lessThan(1000),
      reason: 'At 1000 the per-ABI offsets start colliding: build 1008 on '
          'armeabi-v7a and build 8 on arm64-v8a both stamp versionCode 2008.',
    );
  });

  test('a semver-derived build number would be rejected', () {
    // Negative case: the scheme this project deliberately does not use.
    int semverDerived(int major, int minor, int patch) =>
        major * 10000 + minor * 100 + patch;
    expect(semverDerived(0, 11, 3), greaterThanOrEqualTo(1000));
    // ...and here is the collision it would cause, spelled out.
    expect(semverDerived(0, 11, 3) + 1000, semverDerived(0, 1, 3) + 2000);
  });
}
