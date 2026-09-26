# Installing Quicklog on Android without F-Droid

The easiest way to install Quicklog is the F-Droid repository at
<https://github.com/snonux/fdroid>, which also keeps it updated (see the
[README](../README.md#installation)). This page is for installing the APK by
hand instead. You get no automatic updates this way: repeat the steps for every
new release.

## Download a release APK

Release APKs are attached to the
[GitHub releases](https://github.com/snonux/quicklog/releases). Each release has
one APK per CPU architecture; pick the one that matches your phone:

| APK | For |
| --- | --- |
| `app-arm64-v8a-release.apk` | Almost every phone from the last ten years |
| `app-armeabi-v7a-release.apk` | Older 32-bit phones |
| `app-x86_64-release.apk` | Emulators and x86 devices |

If you are not sure, take `arm64-v8a`. Android refuses to install an APK built
for the wrong architecture, so a wrong guess costs nothing.

Open the APK on the phone (from the browser's downloads or a file manager) and
confirm the install. Android asks once to allow "Install unknown apps" for the
app you open it from.

To install from a computer over USB instead, with USB debugging enabled:

```sh
adb install -r app-arm64-v8a-release.apk
```

## Build it yourself

With Flutter and the Android SDK set up (see
[Requirements](../README.md#requirements)):

```sh
flutter build apk --release --split-per-abi
adb install -r build/app/outputs/flutter-apk/app-arm64-v8a-release.apk
```

A build signed with a key other than the release key cannot update an
installed release build, and vice versa. Android rejects the update with a
signature mismatch; uninstall first (this deletes notes kept in the default
app directory, so copy them off the phone before).

## Switching to F-Droid later

The APKs on GitHub are the same signed files the F-Droid repository serves, so
after adding the repository F-Droid picks up the installed app and updates it
in place, with no reinstall.

## Next steps

Quicklog works out of the box and needs no permissions. To log into a folder
of your choosing, such as a synced notes vault, see
[Setting up a custom log directory](installation.md).
