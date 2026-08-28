# Working on Quicklog

Quicklog is a Flutter app (Android primary, Linux desktop for development) that
writes each note to its own timestamped Markdown file. Notes are plain files in
a plain directory; the app itself never syncs and holds no network permission.

Before calling anything done: `flutter analyze` and `flutter test` must both be
clean. For anything touching the Android build, build a release APK too --
`flutter build apk --release --split-per-abi` -- because the debug build hides
signing and packaging problems.

Toolchain: JDK **17 or 21** only. Gradle 8.14 rejects JDK 25 outright
(`What went wrong: 25.0.4`), and 25/26 are the only JDKs Fedora packages, so
point Flutter at a Temurin build: `flutter config --jdk-dir=$HOME/jdk21`.

## Releasing

The full runbook is [docs/fdroid-submission.md](./docs/fdroid-submission.md).
The traps that are easy to step on, and cheap to avoid:

**Bump the build number, and keep it under 1000.** `version:` in `pubspec.yaml`
is `<semver>+<counter>`. The counter is a plain counter on purpose. Forgetting
to bump it is the dangerous mistake: F-Droid's tag-based update check just
reports "up to date" and the release silently never ships -- no error anywhere.
`test/version_test.dart` guards the 1000 ceiling but cannot guard this.

**Do not derive the counter from the semver.** `--split-per-abi` makes Flutter
stamp `counter + 1000/2000/4000` into the per-ABI APKs, so any scheme that lets
the counter reach 1000 eventually collides two releases on one APK version code.

**Write the changelog three times.** F-Droid looks it up by the *APK's* version
code, and split builds have three. For counter `n` they are named
`1000+n`, `2000+n` and `4000+n` under
`fastlane/metadata/android/en-US/changelogs/` -- see the copy loop in the
runbook. A changelog named after the pubspec counter alone is never read.

**Never remove the `dependenciesInfo` block from `android/app/build.gradle.kts`.**
Without it AGP embeds a Google Play dependency-metadata blob in the APK signing
block, and F-Droid's scanner fails the build with "Found extra signing block
'Dependency metadata'". Note that `fdroid scanner` 2.4.5 does *not* catch this
-- their CI runs a newer version, so a local pass is not proof. Check directly
if in doubt: the block id to look for in the APK signing block is `0x504b4453`.

**Keep `.flutter-version` current.** The F-Droid recipe checks that file out in
the Flutter srclib, so a stale value means F-Droid builds with the wrong SDK.

**Tag `vX.Y.Z`, matching `pubspec.yaml` exactly**, and make sure the tagged tree
contains `.flutter-version` and `fastlane/` -- the recipe reads the first under
`bash -e`, and the F-Droid app page takes all of its text from the second.

Store text lives in `fastlane/metadata/android/en-US/` in this repo, not in the
fdroiddata merge request. Summary is capped at 80 characters and takes no
trailing period; changelogs at 500.

## Editing the F-Droid recipe

`docs/fdroid/org.buetow.quicklog.yml` is the file that gets copied into
fdroiddata. Two constraints that are invisible until they break:

- **Field order is canonical.** `fdroid rewritemeta` must produce no diff, or
  fdroiddata's CI fails the pipeline. `VercodeOperation` comes before
  `UpdateCheckData`.
- **The three `Builds:` blocks must stay in ascending versionCode order.**
  `checkupdates.py` zips them in file order against sorted version codes, so
  reordering them for readability pairs the wrong ABI with the wrong code and
  F-Droid rejects the build.

Do not add a `sudo:` step to install a JDK. `checkupdates.py` strips
`apt-get install -y openjdk-17-jdk-headless` and `update-alternatives --auto
java` verbatim from auto-generated build blocks, so the workaround would vanish
on the first automatic update. Pin the toolchain inside the repository instead.

## Signing

`android/key.properties` is git-ignored and optional. When present all four of
`storeFile`, `storePassword`, `keyAlias`, `keyPassword` are required and the
build fails loudly if any are missing; a relative `storeFile` resolves against
`android/app/`. Without it, release builds fall back to the debug keys and say
so. F-Droid re-signs either way, so the release build type must never *require*
a keystore.

## Testing gotchas

**No `dart:io` or `Process.run` directly in a `testWidgets` body.** The body runs
on a fake clock where those futures never complete, and the test hangs rather
than failing. Do filesystem setup in `setUp`, or route it through
`tester.runAsync`. `test/io_pump.dart` has `pumpWithIo` for widgets that read
real files. To make a path unwritable without a subprocess, put it under a
regular file -- a directory can never be created there.

## Driving the app on an emulator

Flutter exposes its semantics tree, so element bounds can be read rather than
guessed:

```sh
adb shell uiautomator dump /sdcard/ui.xml
adb shell cat /sdcard/ui.xml | tr '<' '\n<' \
  | grep -E 'content-desc="[^"]+"' \
  | sed -E 's/.*content-desc="([^"]*)".*bounds="([^"]*)".*/\1  @ \2/'
```

Two things that will mislead you: a `Card`'s text does **not** appear in that
dump, so verify visual state on a screenshot (`adb exec-out screencap -p`) and
never on the dump alone; and the soft keyboard shifts every bound, so dismiss it
(`adb shell input keyevent 4`) before tapping anything near the bottom.
