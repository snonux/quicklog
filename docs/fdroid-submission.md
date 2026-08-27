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
| Monotonic `versionCode` | plain counter in `pubspec.yaml`; `0.1.3` is release `8` |
| Release build works without a keystore | `android/app/build.gradle.kts` — falls back to the debug keys, and F-Droid re-signs anyway |
| Pinned Flutter SDK | [`.flutter-version`](../.flutter-version), read by the F-Droid build recipe |
| Store description, icon, screenshots | `fastlane/metadata/android/en-US/` |
| Per-release changelog | `fastlane/metadata/android/en-US/changelogs/<apkVersionCode>.txt`, one per ABI |
| Build recipe for `fdroiddata` | [`fdroid/org.buetow.quicklog.yml`](fdroid/org.buetow.quicklog.yml) |

## Cutting a release

Do this before every submission, and before every update afterwards.

1. Bump `version:` in `pubspec.yaml` — both halves. The build number is a plain
   counter: `0.1.3+8` becomes `0.2.0+9`. Do not switch it to something derived
   from the semver; see the version-code table below for why it has to stay
   below 1000.
2. Write the changelog (max 500 characters). F-Droid looks it up by the
   version code *of the published APK*, and with per-ABI splits there are three
   of those — so the same text has to exist under all three names:

   ```sh
   n=9                                    # the new pubspec build number
   cd fastlane/metadata/android/en-US/changelogs
   $EDITOR "$((2000 + n)).txt"            # write it once
   for off in 1000 4000; do cp "$((2000 + n)).txt" "$((off + n)).txt"; done
   ```
3. If the release was built with a different Flutter SDK, update
   `.flutter-version`. The F-Droid recipe checks that file out in the Flutter
   srclib, so a stale value means F-Droid builds with the wrong SDK.
4. `flutter analyze && flutter test && flutter build apk --release --split-per-abi`
5. Commit, then tag with a leading `v`: `git tag -a v0.2.0 -m 'v0.2.0'`
6. `git push && git push --tags`

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

| ABI | `VercodeOperation` | versionCode at `0.1.3+8` |
| --- | --- | --- |
| `armeabi-v7a` | `%c + 1000` | 1008 |
| `arm64-v8a` | `%c + 2000` | 2008 |
| `x86_64` | `%c + 4000` | 4008 |

Those offsets are not a choice. Flutter's Gradle plugin computes
`abiVersionCode * 1000 + versionCode`, with the ABI codes fixed at 1
(armeabi-v7a), 2 (arm64-v8a) and 4 (x86_64) — `ABI_VERSION` in
`FlutterPluginConstants.kt`, where 3 is reserved for the since-removed 32-bit
x86, and the arithmetic in `FlutterPlugin.kt`. Both those sources and
`aapt2 dump badging` on the real build output agree. F-Droid
rejects a build whose APK version code differs from the recipe, so if a future
Flutter release changes the scheme, rebuild locally and re-read the codes
before touching these numbers.

Two consequences worth spelling out:

* **The pubspec build number must stay below 1000.** Two releases whose build
  numbers differ by exactly 1000, 2000 or 3000 would produce the *same* APK
  version code — e.g. build 8 on arm64 and build 1008 on armeabi-v7a both give
  2008. A plain counter reaches 1000 only after a thousand releases; a scheme
  derived from the semver reaches it almost immediately, which is why this
  project does not use one.
* Android installs the highest version code an APK is compatible with, and
  Flutter's ABI codes happen to rank `armeabi-v7a < arm64-v8a < x86_64`, so a
  64-bit phone gets the arm64 build rather than the 32-bit one. That ordering
  comes from Flutter, not from a rule of F-Droid's.
* **Do not reorder the three `Builds:` blocks.** `checkupdates.py` pairs
  `builds[-3:]` *in file order* with the `VercodeOperation` results *sorted
  ascending*. Sorted by readability instead of by version code, auto-update
  would pair the `--target-platform=android-arm` command with the `+4000` code,
  and F-Droid would then reject the APK for not matching its declared version
  code.

`CurrentVersionCode` must be the *highest* of the three (4008), not the build
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
JDK 17 (the README's toolchain note), so the two differ. Gradle 8.14 with AGP
8.11.1 and `sourceCompatibility 17` is expected to build fine under 21, but
that combination has not been exercised on this machine — no JDK 21 installed —
so treat it as the most likely first-build surprise.

If it does fail, do **not** reach for a `sudo:` step: `checkupdates.py` carries
a `trixie_blocklist` containing `apt-get install -y openjdk-17-jdk-headless`
and `update-alternatives --auto java` verbatim, and strips those lines out of
every auto-generated build block — so with `AutoUpdateMode: Version` the
workaround would quietly disappear on the first automatic update after
submission. Pin the toolchain from inside the repository instead (a Gradle
Java toolchain or `org.gradle.java.home`), where auto-update cannot undo it.

## Known rough edges

**Launcher icon source.** `icon.png` at the repo root — the source
`flutter_launcher_icons` generates the Android mipmaps from — is only 64x64, so
the in-APK launcher icon is upscaled and soft. The F-Droid website uses
`fastlane/.../images/icon.png` (512x512, generated from `logo.png`), so the app
page looks right, but regenerating the launcher icons from the 600x600
`logo.png` would fix the icon on the device itself.

**Stray file in the tagged tree.** `ql-250516-000347.md` in the repository root
is a Quicklog log entry ("7 share:ma Reading Articles") that was committed by
accident. It ships inside every source tarball F-Droid builds and archives.
Harmless, but worth deleting before submission so a reviewer does not have to
ask what it is.

## Screenshots

`fastlane/metadata/android/en-US/images/phoneScreenshots/` currently holds one
screenshot (the editor). F-Droid renders however many are there, but two or
three read much better on the app page — the Entries browser and Preferences
are the obvious additions. Capture them at the device's native resolution and
drop them in as `2.png`, `3.png`.
