# Publishing Quicklog on F-Droid

This is the runbook for getting Quicklog into the main F-Droid repository,
following the [Quick Start
Guide](https://f-droid.org/en/docs/Submitting_to_F-Droid_Quick_Start_Guide/).

F-Droid does not accept uploaded APKs. It builds every app itself, from a
tagged commit of this repository, and signs the result with the F-Droid key.
So the work splits in two: making *this* repo buildable and describable by
F-Droid (done, see below), and opening a merge request against F-Droid's
`fdroiddata` repository (needs a GitLab account, so it is a manual step).

## What is already in place

| Requirement | Where |
| --- | --- |
| Public source repository | <https://github.com/snonux/quicklog> |
| FOSS licence | [`LICENSE`](../LICENSE) — MIT |
| No proprietary dependencies | `pubspec.yaml` — Flutter, `shared_preferences`, `path_provider`, `path`, `intl`. No Firebase, no Google Mobile Services, no analytics, no network permission. |
| Release tag matching `versionName` | tag `vX.Y.Z` ↔ `version: X.Y.Z+<code>` in `pubspec.yaml` |
| Monotonic `versionCode` | plain counter in `pubspec.yaml`; `0.1.5` is release `10` |
| Release build works without a keystore | `android/app/build.gradle.kts` — falls back to the debug keys, and F-Droid re-signs anyway |
| Pinned Flutter SDK | [`.flutter-version`](../.flutter-version), read by the F-Droid build recipe |
| Store description, icon, screenshots | `fastlane/metadata/android/en-US/` |
| Per-release changelog | `fastlane/metadata/android/en-US/changelogs/<apkVersionCode>.txt`, one per ABI |
| Build recipe for `fdroiddata` | [`fdroid/org.buetow.quicklog.yml`](fdroid/org.buetow.quicklog.yml) |

## Cutting a release

Do this before every submission, and before every update afterwards.

1. Bump `version:` in `pubspec.yaml` — both halves. The build number is a plain
   counter: `0.1.5+10` becomes `0.2.0+11`.
2. Write the changelog (max 500 characters). F-Droid looks it up by the
   version code *of the published APK*, and with per-ABI splits there are three
   of those — so the same text has to exist under all three names:

   ```sh
   n=11                                   # the new pubspec build number
   cd fastlane/metadata/android/en-US/changelogs
   $EDITOR "$((n * 10 + 2)).txt"          # write it once (arm64)
   for abi in 1 3; do cp "$((n * 10 + 2)).txt" "$((n * 10 + abi)).txt"; done
   ```
3. If the release was built with a different Flutter SDK, update
   `.flutter-version`. The F-Droid recipe checks that file out in the Flutter
   srclib, so a stale value means F-Droid builds with the wrong SDK.
4. `flutter analyze && flutter test`
5. Commit, then tag with a leading `v`: `git tag -a v0.2.0 -m 'v0.2.0'`, and
   `git push && git push --tags`
6. Build the release **from `/tmp/build`** and publish it. The path matters: the
   Dart AOT snapshot embeds absolute source paths, so a build from anywhere else
   will not reproduce and F-Droid will reject it.

   ```sh
   rm -rf /tmp/build
   git clone --branch v0.2.0 --depth 1 ~/git/quicklog /tmp/build
   cp ~/git/quicklog/android/key.properties /tmp/build/android/
   cd /tmp/build
   export PUB_CACHE=/tmp/build/.pub-cache
   flutter pub get --enforce-lockfile
   flutter build apk --release --split-per-abi
   gh release create v0.2.0 --title v0.2.0 --notes-file - \
       build/app/outputs/flutter-apk/app-*-release.apk
   ```

7. Bump `versionName`, the three `versionCode`s, `commit` (the **full hash**, not
   the tag) and `CurrentVersion*` in `docs/fdroid/org.buetow.quicklog.yml`, and
   open an fdroiddata MR — or let `AutoUpdateMode: Version` do it for you.

The tagged tree must contain `.flutter-version` and `fastlane/` — the recipe
reads the first in `prebuild:` under `bash -e` (a missing file aborts the
build), and the F-Droid app page has no description of its own: it takes all of
its text from `fastlane/metadata/android/en-US/` at the tagged commit.

The tag name matters: F-Droid's `UpdateCheckMode: Tags` looks for new tags and
reads the version out of `pubspec.yaml` at that tag.

## Submitting to fdroiddata

Only needed once. Afterwards `AutoUpdateMode: Version` picks up new tags on its
own and F-Droid generates the build blocks itself.

1. Fork <https://gitlab.com/fdroid/fdroiddata> and clone your fork.
2. `git checkout -b org.buetow.quicklog`
3. Copy the recipe into place:

   ```sh
   cp /path/to/quicklog/docs/fdroid/org.buetow.quicklog.yml \
      metadata/org.buetow.quicklog.yml
   ```

4. Check all three `Builds:` entries still name the tag you actually pushed
   (`commit: v0.1.3`) and that `CurrentVersion` / `CurrentVersionCode` match
   (see the version-code table below).
5. Lint and build it locally. There is no Fedora package; the
   [install docs](https://f-droid.org/docs/Installing_the_Server_and_Repo_Tools/)
   point Fedora and Arch users at a virtualenv:

   ```sh
   python3 -m venv .venv && .venv/bin/pip install fdroidserver
   . .venv/bin/activate
   fdroid lint org.buetow.quicklog
   fdroid rewritemeta org.buetow.quicklog
   fdroid checkupdates --allow-dirty org.buetow.quicklog
   fdroid build org.buetow.quicklog
   ```

   Plain `fdroid build` runs in *your* environment, not F-Droid's. To reproduce
   what the build server actually does you need `fdroid build --server`, which
   spins up the Vagrant VM described in
   [Build Server Setup](https://f-droid.org/docs/Build_Server_Setup/) —
   VirtualBox by default, with libvirt/QEMU available via `Vagrantfile.yaml`.
   Pushing to your fork is usually easier: fdroiddata's CI runs lint,
   rewritemeta, checkupdates and a real build for changed `metadata/` files.

   Run `fdroid rewritemeta` before every push. fdroiddata's CI fails the
   pipeline on any diff it produces, and it enforces a canonical field order
   (`VercodeOperation` before `UpdateCheckData`, for instance) that is easy to
   get wrong by hand.
6. `git commit -m 'New App: org.buetow.quicklog'`, push, and open a merge
   request against `fdroid/fdroiddata`.

Expect review comments about licensing, dependencies and anti-features. Once
merged, the app appears in the repository roughly 24–48 hours later, and on
f-droid.org a little after that.

## Reproducible builds

F-Droid builds from source, downloads the APK published on the GitHub release,
and ships **your** signed APK if the two match apart from the signature. Users
can then verify the binary against public source and move between your builds
and F-Droid's without uninstalling.

Three things make it work, and breaking any one of them fails the build:

* `binary:` on each build block points at the release asset for that ABI.
* `AllowedAPKSigningKeys` pins the SHA-256 of the release certificate
  (`87f168a1e524cb5a218653f3630e08d064c4af7a0393b39b38ff0f1a350b74b0`).
* Both sides build at the identical absolute path, `/tmp/build`. The recipe
  moves its checkout there; the release procedure above clones there. Without
  this, `libapp.so` and `libdartjni.so` differ and everything else matches --
  that is the signature of a path mismatch, not a real difference.

The signing key at `~/keys/quicklog-release.jks` is now the app's identity.
Losing it ends the ability to update Quicklog for existing users, permanently.

## Things reviewers are likely to ask about

**`MANAGE_EXTERNAL_STORAGE`.** Quicklog declares "All files access" because
`Preferences → Directory` accepts a typed path rather than going through the
system file picker, so a user-chosen notes vault is not reachable any other
way. It is optional at runtime: the default directory,
`/storage/emulated/0/Android/data/org.buetow.quicklog/files/`, needs no
permission at all, and
GrapheneOS users can confine the app with Storage Scopes
([`installation.md`](installation.md)). This is worth stating up front in the
merge request. It is not one of F-Droid's anti-features, so
`AntiFeatures:` is intentionally absent from the recipe.

**Build size and the per-ABI version codes.** The recipe builds one APK per ABI
rather than a single universal one, which takes the download from 50.5 MB to
15.5-19.5 MB. That means three build blocks, and three version codes derived from
the build number in `pubspec.yaml` by `VercodeOperation`:

| ABI | `VercodeOperation` | versionCode at `0.1.5+10` |
| --- | --- | --- |
| `armeabi-v7a` | `%c * 10 + 1` | 101 |
| `arm64-v8a` | `%c * 10 + 2` | 102 |
| `x86_64` | `%c * 10 + 3` | 103 |

These are not Flutter's own numbers. Flutter's Gradle plugin would stamp
`abiVersionCode * 1000 + versionCode`, which collides two releases as soon as
the build number reaches 1000. The `applicationVariants` block at the bottom of
`android/app/build.gradle.kts` overrides that with F-Droid's convention, moving
the ABI digit to the end so the counter has no ceiling. F-Droid asked for this
in [!47118](https://gitlab.com/fdroid/fdroiddata/-/merge_requests/47118); the
snippet comes from the
[Quick Start Guide](https://f-droid.org/en/docs/Submitting_to_F-Droid_Quick_Start_Guide/#setup-abi-split).

F-Droid rejects a build whose APK version code differs from what the recipe
predicted, so the Gradle block and `VercodeOperation` must always agree.
`test/version_test.dart` pins the arithmetic; `aapt2 dump badging` on a real
build confirms it end to end.

Two more consequences:

* Android installs the highest version code a device can run, and the scheme
  ranks `armeabi-v7a < arm64-v8a < x86_64`, so a 64-bit phone gets the arm64
  build rather than the 32-bit one.
* **Do not reorder the three `Builds:` blocks.** `checkupdates.py` pairs
  `builds[-3:]` *in file order* with the `VercodeOperation` results *sorted
  ascending*. Sorted by readability instead of by version code, auto-update
  would pair the `--target-platform=android-arm` command with the `* 10 + 3`
  code, and F-Droid would then reject the APK for not matching its declared
  version code.

`CurrentVersionCode` must be the *highest* of the three (103), not the build
number in `pubspec.yaml`.

**Where the Dart packages get fetched.** `prebuild:` sets
`PUB_CACHE=$(pwd)/.pub-cache` and runs `flutter pub get --enforce-lockfile`
there, following F-Droid's
[`templates/build-flutter.yml`](https://gitlab.com/fdroid/fdroiddata/-/blob/master/templates/build-flutter.yml).
`prebuild:` runs before `scanner.scan_source()`, so keeping the cache inside the
build directory is what lets F-Droid's scanner inspect every Dart dependency —
which is the whole reason a reviewer will look for this pattern.
`scandelete: [.pub-cache]` does not remove the directory — it deletes only the
individual files the scanner objects to (`removeproblem()` in
`fdroidserver/scanner.py` calls `os.remove()` per file), so the packages Gradle
needs survive into the `build:` step. Today those deletions are the WebAssembly
blobs in `shared_preferences`' bundled DevTools extension and the archive
fixtures in `archive`.

There is a trap in the other direction, though: `scanner.py` reports
`Unused scandelete path` as an *error* if nothing under `.pub-cache` turns out
to be deletable, and `build.py` turns any scanner error into a failed build. So
a future dependency bump that drops those binaries would break the build with a
message that points at the wrong thing. If that happens, drop the
`scandelete:` line rather than trying to make the scanner find something.

**JDK version.** The recipe pins no JDK, and F-Droid's buildserver does not
give you 17: `provision-apt-get-install` installs `default-jdk-headless` on a
Debian trixie base and then runs `update-java-alternatives --set` on the
*highest* JDK present, which today means JDK 21. Local release builds here use
JDK 17, so the two differ — and that is fine. `flutter build apk --release
--split-per-abi` was run against Temurin 21.0.12.1 on this project: all three
APKs build and stamp the same version codes as the JDK 17 build. No `sudo:`
step is needed.

Should a future toolchain bump break that, do **not** reach for one anyway:
`checkupdates.py` carries a `trixie_blocklist` containing
`apt-get install -y openjdk-17-jdk-headless` and `update-alternatives --auto
java` verbatim, and strips those lines out of every auto-generated build block —
so with `AutoUpdateMode: Version` the workaround would quietly disappear on the
first automatic update after submission. Pin the toolchain from inside the
repository instead (a Gradle Java toolchain or `org.gradle.java.home`), where
auto-update cannot undo it.

## Screenshots

`fastlane/metadata/android/en-US/images/phoneScreenshots/` holds four: the
editor (`1.png`, from a real phone at 1080x2340), the Entries browser
(`2.png`), the full-screen delete confirmation (`3.png`) and Preferences
(`4.png`) — the last three captured at 1080x2220 on a Pixel 3a API 34 emulator
running the x86_64 release APK. Mixed sizes are fine — F-Droid scales them.

To recapture, boot the AVD, `adb install -r` the x86_64 release APK, and drive
it with `adb shell input tap`. Flutter exposes its semantics tree to
`uiautomator dump`, so element bounds can be read out rather than guessed —
but note the dump is not a substitute for looking: a `Card`'s text does not
show up in it, so check state on the screenshot, not the dump. Bounds also
shift when the soft keyboard opens; dismiss it before tapping a button near
the bottom.

```sh
adb shell uiautomator dump /sdcard/ui.xml
adb shell cat /sdcard/ui.xml | tr '<' '\n<' \
  | grep -E 'content-desc="[^"]+"' \
  | sed -E 's/.*content-desc="([^"]*)".*bounds="([^"]*)".*/\1  @ \2/'
adb exec-out screencap -p > shot.png
```
