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

**Bump the build number.** `version:` in `pubspec.yaml` is `<semver>+<counter>`.
Forgetting to bump it is the dangerous mistake: F-Droid's tag-based update check
just reports "up to date" and the release silently never ships -- no error
anywhere, and no test can catch it.

**The per-ABI version code scheme is `counter * 10 + abi`** (1 armeabi-v7a,
2 arm64-v8a, 3 x86_64), set by the `applicationVariants` block at the bottom of
`android/app/build.gradle.kts` and mirrored by `VercodeOperation` in the recipe.
The two must agree or F-Droid rejects the build. Do not drop that block: without
it Flutter stamps `abi * 1000 + counter` instead, which collides two releases
once the counter reaches 1000. F-Droid asked for this scheme in fdroiddata!47118.

**Write the changelog three times.** F-Droid looks it up by the *APK's* version
code, and split builds have three. For counter `n` they are named `n0+1`, `n0+2`
and `n0+3` under `fastlane/metadata/android/en-US/changelogs/` -- so counter 10
gives `101.txt`, `102.txt`, `103.txt`. A changelog named after the pubspec
counter alone is never read.

**Never remove the `dependenciesInfo` block from `android/app/build.gradle.kts`.**
Without it AGP embeds a Google Play dependency-metadata blob in the APK signing
block, and F-Droid's scanner fails the build with "Found extra signing block
'Dependency metadata'". Note that `fdroid scanner` 2.4.5 does *not* catch this
-- their CI runs a newer version, so a local pass is not proof. Check directly
if in doubt: the block id to look for in the APK signing block is `0x504b4453`.

**Release builds are path-sensitive in two places.** F-Droid rebuilds the app
from source and requires the result to match the published APK byte for byte, so
anything that leaks a build-host path into a binary breaks the check. Two do:

* `libapp.so` (the Dart AOT snapshot) embeds the **source** path -- so build from
  `/tmp/build`, which is where the F-Droid recipe moves its own checkout.
* `libdartjni.so` (native C from the transitive `jni` package, compiled by
  CMake + NDK) varies with the **Android SDK** path. F-Droid's builder uses
  `/opt/android-sdk`, so the release must be built against that path too.
  Verified by building one commit twice changing only `sdk.dir`: the file's
  sha256 went from `09db6068...` to `1f7a3a12...`.

Setting `ANDROID_HOME` is not enough for the second one: the Flutter tool writes
`sdk.dir` into `android/local.properties` from its own config, and that wins. Use
`flutter config --android-sdk`, and put it back afterwards.

**Publish the signed APKs to a GitHub release named after the tag.** The recipe's
`binary:` URLs point at them and F-Droid diffs its own build against them. A
release with missing or stale assets fails the build, not just the check.
`AllowedAPKSigningKeys` pins the signing certificate's SHA-256, so signing with a
different key fails too.

**The signing key at `~/keys/quicklog-release.jks` is the app's identity.** Keep
it; `android/key.properties` points at it and every release build needs it. If it
is ever lost, existing users can never be updated again -- a new key means a new
app. It is backed up offline; that backup is the real safety net.

### The release build, start to finish

```sh
# 1. one-time on a new machine: F-Droid's builder path
sudo ln -sfn "$HOME/Android/Sdk" /opt/android-sdk

# 2. point Flutter at that path for the duration
flutter config --android-sdk /opt/android-sdk

# 3. build the tag from /tmp/build with its own pub cache
rm -rf /tmp/build
git clone --branch vX.Y.Z ~/git/quicklog /tmp/build
cp ~/git/quicklog/android/key.properties /tmp/build/android/
cd /tmp/build
export ANDROID_HOME=/opt/android-sdk PUB_CACHE=/tmp/build/.pub-cache
export JAVA_HOME=$HOME/jdk21          # or jdk17; 25+ is rejected by Gradle
flutter pub get --enforce-lockfile
flutter build apk --release --split-per-abi
grep sdk.dir android/local.properties  # must say /opt/android-sdk

# 4. publish, then restore your normal SDK path
gh release create vX.Y.Z --title vX.Y.Z build/app/outputs/flutter-apk/app-*-release.apk
flutter config --android-sdk "$HOME/Android/Sdk"
```

To check reproducibility before pushing, run `fdroid build org.buetow.quicklog`
in the fdroiddata checkout with `ANDROID_HOME=/opt/android-sdk` **and** Flutter's
config pointed there. With the config left on the home path the build silently
uses the wrong SDK and the comparison fails for the wrong reason.

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

- **`fdroid rewritemeta` strips YAML comments** from the build commands, so do
  not explain anything inside the recipe -- it will be deleted and the CI
  rewritemeta check will fail on the diff. Put the reasoning in this file or in
  `docs/fdroid-submission.md` instead. Run `fdroid rewritemeta` after *every*
  recipe edit, not just the first.
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
