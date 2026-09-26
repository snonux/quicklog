# Quicklog

![Quicklog](./logo-small.png)

Tiny GUI app to quickly jot a thought into a timestamped Markdown file.
Originally a Go/Fyne app called *Quicklogger* — this is the Flutter rewrite,
renamed to **Quicklog**, targeting Android (primary) and Linux desktop
(development).

The intent is the same as before: type a quick note on Android, hit **Log
text**, and let Syncthing copy the resulting `ql-YYMMDD-HHMMSS.md` file to your
home computer.

![Screenshot](./screenshot-android.png)
![Screenshot](./screenshot-fedora.png)

## Features

- Single-screen text editor with character counter and a one-shot warning at
  5,000 characters.
- Each press of **Log text** writes the current text to a new file named
  `ql-YYMMDD-HHMMSS.md` in the configured directory.
- **Preferences**: configurable log directory, Local vs S3 storage mode, and
  an "Auto-log shared text" toggle. S3 mode stores endpoint/region/bucket/keys
  on-device only (paste from `~/.config/garage/quicklog.env` on a laptop).
- **Optional S3**: same `ql-*.md` object keys against a path-style S3 endpoint
  (defaults aimed at Garage), either **S3 only** or **Local + S3** (dual
  write: every note lands in the local directory *and* the bucket). On S3
  failure a note is written to the local directory on the spot, so it is
  never lost and never asks you to re-save; the app then skips S3 for an
  hour with a Retry control. No telemetry; default remains local-only.
- **Entry browser**: list of previous entries (newest first) with a viewer.
- **Edit entries**: from the list (pencil icon) or from the entry viewer. The
  editor writes back to the same file, so the note keeps its creation
  timestamp and its place in the list. Save and Revert stay disabled until
  something changes, and leaving with unsaved changes asks first.
- **Delete entries**: from the list (trash icon or long-press) or from the
  entry viewer. Deletion always goes through a full-screen confirmation that
  shows the filename, timestamp and a preview of the note — the file is
  removed for good, there is no trash folder.
- **Share to Quicklog** on Android: share text from any app and Quicklog
  either prefills the editor or logs it immediately, depending on the
  preference.

## Installation

### Android

Install Quicklog from the F-Droid repository at
**<https://github.com/snonux/fdroid>**. Add the repository to the F-Droid app
once (the README there has a one-tap link and a QR code), search for Quicklog
and install it. F-Droid then keeps it updated.

Prefer not to use F-Droid? [docs/install-android.md](./docs/install-android.md)
explains how to download and install the APK by hand.

### Linux

Quicklog runs as a desktop app on Linux too; there are no prebuilt packages, so
[docs/install-linux.md](./docs/install-linux.md) walks through building and
installing it from source.

## Releases

Versions live in a single place: the `version:` line of `pubspec.yaml`, written
as `<semver>+<buildNumber>`. The build number is a plain counter — bump it by
one per release. Android's `versionName` and `versionCode` are derived from it,
and every release commit gets a matching `vX.Y.Z` git tag.

`.flutter-version` pins the Flutter SDK a release was built with; the F-Droid
build recipe reads it, so bump it whenever the toolchain moves.

Note that split APKs do not carry that number verbatim. `android/app/build.gradle.kts`
turns it into `buildNumber * 10 + abi`, with 1, 2 and 3 for armeabi-v7a, arm64-v8a
and x86_64, so `0.2.1+12` ships as 121 / 122 / 123. This is F-Droid's convention
and it replaces Flutter's own `abi * 1000 + buildNumber`, which would collide two
releases once the counter reached 1000.

Quicklog is packaged for F-Droid, which builds it from source and signs it with
its own key. Store text, icon and screenshots come from
`fastlane/metadata/android/en-US/`, the build recipe to submit to `fdroiddata`
is [docs/fdroid/org.buetow.quicklog.yml](./docs/fdroid/org.buetow.quicklog.yml),
and the submission runbook is
[docs/fdroid-submission.md](./docs/fdroid-submission.md).

Release APKs built locally are signed with your own keystore if
`android/key.properties` exists (git-ignored; all four of `storeFile`,
`storePassword`, `keyAlias`, `keyPassword` are required, and the build fails
loudly if any are missing), and with the debug keys otherwise. A relative
`storeFile` is resolved against `android/app/`, not against the directory
`key.properties` itself lives in.

## Requirements

- [Flutter](https://flutter.dev) stable channel (3.41+).
- For Android builds: Android SDK + JDK 17 or 21. Fedora only packages 25 and
  26, which Gradle 8.14 refuses ("What went wrong: 25.0.4"), so install a
  Temurin build and point Flutter at it:
  `flutter config --jdk-dir=$HOME/jdk21`. GraalVM 17 from Fedora's repos works
  too. F-Droid's build server runs JDK 21; both 17 and 21 have been used to
  build the release APKs for this project.
- For Linux desktop builds: `gtk3-devel`, `mesa-demos`, `clang`, `cmake`,
  `ninja-build`, `pkg-config`, `xz-devel`.

## Build and Run

### Linux desktop

```sh
flutter run -d linux              # dev with hot reload
flutter build linux --release     # release bundle: build/linux/x64/release/bundle/
```

### Android

```sh
flutter run -d <device-id>        # dev on a connected device
flutter build apk --release       # fat APK with all ABIs
```

### Cross-compile from amd64 Linux to ARM Android APK

Unlike the previous Fyne build, no Docker / Podman / `fyne-cross` / NDK is
needed. Flutter's Dart AOT compiler emits ARM machine code directly from x86_64.

```sh
# Per-ABI split APKs (smaller, recommended for distribution)
flutter build apk --release --split-per-abi
# → build/app/outputs/flutter-apk/app-arm64-v8a-release.apk     (modern phones)
# → build/app/outputs/flutter-apk/app-armeabi-v7a-release.apk   (older 32-bit)
# → build/app/outputs/flutter-apk/app-x86_64-release.apk        (emulators)

# ARM64 only
flutter build apk --release --target-platform android-arm64
```

Install on the device:

```sh
adb install -r build/app/outputs/flutter-apk/app-arm64-v8a-release.apk
```

### Tests

```sh
flutter test
flutter analyze
```

## Share with Quicklog on Android

From any app that can share text, choose **Share** → **Quicklog**. With
auto-log off (default), the text opens in the editor for review. Toggle
"Auto-log shared text" in Preferences to have shared text written
straight to disk.

## Optional S3 mode

Preferences → **S3 only** writes notes as objects named `ql-YYMMDD-HHMMSS.md`
to a user-configured S3-compatible endpoint (path-style). Defaults target
`https://garage.f3s.buetow.org`, region `garage`, bucket `quicklog`. Paste the
access key and secret from `~/.config/garage/quicklog.env` on a development
machine; Android has no automatic import of that file. **Test connection**
probes without writing prefs; **Save** is what persists secrets. Credentials
live only in SharedPreferences and are never logged. If the S3 write fails
while logging, Quicklog writes that note to the local directory immediately
(same `ql-*.md` name) and tells you it was saved on this device — you do not
re-save it. The app then uses the local directory for new notes until you tap
**Retry S3** or an hour elapses / the app cold-starts.

**Local + S3** (dual write) writes every note to the local directory *and*
the bucket under the same `ql-*.md` name. If S3 is unavailable the note is
still saved locally (and you are told), and S3 is skipped for an hour like
above; editing and deleting an entry keeps both copies in sync.

Default mode remains **Local only**. There is no analytics or background sync.
`INTERNET` is declared for the optional S3 path and stays unused in local mode.

### Drain CLI (laptop)

When notes land in the bucket from a phone, pull them into a local notes
directory and delete the remote objects:

```sh
# from this repo, with GARAGE_* exported (see ~/.config/garage/quicklog.env)
dart run bin/quicklog_drain.dart [--dest DIR] [--dry-run] [--force] [--limit N]
# default --dest is ~/Notes/Quicklog
```

Credentials: `GARAGE_ENDPOINT`, `GARAGE_REGION`, `GARAGE_BUCKET`,
`GARAGE_ACCESS_KEY_ID`, `GARAGE_SECRET_ACCESS_KEY`. Fetch is atomic (temp +
rename); remote delete runs only after a successful local write. Existing
local files are skipped unless `--force`. A dry run lists what would move
without creating files or deleting objects.

After drain, ordinary `ql-*.md` files sit on disk for whatever imports them
next (for example Taskwarrior's quicklogger). Dotfiles may wrap the CLI
(`taskwarrior::quicklog_drain` before `quicklogger` in `ti` / `invoke`); that
wrapper is not part of this repository.

## Storage on Android

By default, log files are written to the app-specific external directory at
`/Android/data/org.buetow.quicklog/files/`. No storage permissions are
required; point Syncthing at that folder to sync to your home computer.

You can instead point **Preferences → Directory** at any other folder (e.g.
an existing notes vault) — doing so needs "All files access" or, on
GrapheneOS, Storage Scopes. See
[docs/installation.md](./docs/installation.md) for how to set that up,
including a GrapheneOS Storage Scopes trick that avoids
granting broad filesystem access.
