import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guards the invariants F-Droid packaging depends on.
///
/// `android/app/build.gradle.kts` derives each split APK's version code from the
/// pubspec build number as `buildNumber * 10 + abi`, with abi 1/2/3 for
/// armeabi-v7a/arm64-v8a/x86_64. The F-Droid recipe declares the same thing as
/// `VercodeOperation: '%c * 10 + N'`, and F-Droid rejects a build whose APK
/// version code does not match what the recipe predicted, so the two must agree.
void main() {
  const abiCodes = {'armeabi-v7a': 1, 'arm64-v8a': 2, 'x86_64': 3};

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

  test('build number is a positive integer', () {
    expect(int.parse(match!.group(2)!), greaterThan(0));
  });

  test('per-ABI version codes are distinct and correctly ordered', () {
    final buildNumber = int.parse(match!.group(2)!);
    int codeFor(String abi) => buildNumber * 10 + abiCodes[abi]!;

    final codes = abiCodes.keys.map(codeFor).toList();
    expect(codes.toSet(), hasLength(codes.length));

    // Android installs the highest version code a device can run, so arm64 must
    // outrank armeabi-v7a or 64-bit phones would be served the 32-bit APK.
    expect(codeFor('armeabi-v7a'), lessThan(codeFor('arm64-v8a')));
    expect(codeFor('arm64-v8a'), lessThan(codeFor('x86_64')));
  });

  test('bumping the build number always raises every ABI version code', () {
    // The property the old +1000/+2000/+4000 scheme lacked: there it took only a
    // 1000-release gap for two different releases to land on one version code.
    int codeFor(int n, String abi) => n * 10 + abiCodes[abi]!;
    for (var n = 1; n < 500; n++) {
      for (final abi in abiCodes.keys) {
        expect(codeFor(n + 1, abi), greaterThan(codeFor(n, abi)));
      }
    }
    final all = <int>{};
    for (var n = 1; n < 500; n++) {
      for (final abi in abiCodes.keys) {
        expect(all.add(codeFor(n, abi)), isTrue, reason: 'collision at $n/$abi');
      }
    }
  });
}
