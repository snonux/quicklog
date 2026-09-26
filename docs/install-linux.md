# Installing Quicklog on Linux

There are no prebuilt Linux packages; build the desktop app from source. This
takes a few minutes once Flutter is installed.

## 1. Install the build dependencies

- [Flutter](https://docs.flutter.dev/get-started/install/linux) from the
  stable channel (3.41 or newer), with `flutter` on your `PATH`.
- The Linux desktop toolchain:

  ```sh
  # Fedora
  sudo dnf install clang cmake ninja-build pkg-config gtk3-devel xz-devel mesa-demos

  # Debian / Ubuntu
  sudo apt install clang cmake ninja-build pkg-config libgtk-3-dev liblzma-dev mesa-utils
  ```

Run `flutter doctor` afterwards; the "Linux toolchain" line should be green.
The Android lines do not matter for a desktop build.

## 2. Build

```sh
git clone https://github.com/snonux/quicklog.git
cd quicklog
git checkout "$(git describe --tags --abbrev=0)"   # latest release; skip for main
flutter build linux --release
```

The result is a self-contained bundle in `build/linux/x64/release/bundle/`:
the `quicklog` binary plus its `lib/` and `data/` directories, which have to
stay next to it.

## 3. Install

Copy the whole bundle somewhere permanent and put a link to the binary on your
`PATH`:

```sh
mkdir -p ~/.local/opt ~/.local/bin
rm -rf ~/.local/opt/quicklog
cp -r build/linux/x64/release/bundle ~/.local/opt/quicklog
ln -sf ~/.local/opt/quicklog/quicklog ~/.local/bin/quicklog
```

Optionally add a launcher entry so Quicklog shows up in your desktop's app menu:

```sh
cp icon.png ~/.local/opt/quicklog/icon.png
mkdir -p ~/.local/share/applications
cat > ~/.local/share/applications/org.buetow.quicklog.desktop <<EOT
[Desktop Entry]
Type=Application
Name=Quicklog
Comment=Quickly jot a thought into a timestamped Markdown file
Exec=$HOME/.local/opt/quicklog/quicklog
Icon=$HOME/.local/opt/quicklog/icon.png
Categories=Utility;
EOT
```

To update, pull the new release, build again and repeat the copy.

## 4. Pick a log directory

On Linux Quicklog writes notes into the directory it was started from, which
for a menu launcher is usually your home directory. Open **Preferences →
Directory** once and set the folder you want, for example `~/Notes/Quicklog`.

To uninstall, remove `~/.local/opt/quicklog`, `~/.local/bin/quicklog` and the
`.desktop` file. Your notes stay where they are.
