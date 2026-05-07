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
- **Preferences**: configurable log directory and an "Auto-log shared text"
  toggle.
- **Entry browser**: list of previous entries (newest first) with read-only
  viewer and long-press to delete.
- **Share to Quicklog** on Android: share text from any app and Quicklog
  either prefills the editor or logs it immediately, depending on the
  preference.

## Requirements

- [Flutter](https://flutter.dev) stable channel (3.41+).
- For Android builds: Android SDK + JDK 17 (Flutter's Gradle does not yet
  support newer JDKs). On Fedora, GraalVM 17 works — point Flutter at it with
  `flutter config --jdk-dir=/usr/lib/jvm/graalvm-community-openjdk-17.0.9+9.1`.
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

## Storage on Android

Log files are written to the app-specific external directory at
`/Android/data/org.buetow.quicklog/files/`. No storage permissions are
required; point Syncthing at that folder to sync to your home computer.
