# Installing Quicklog and setting up a custom log directory

## Installing the APK

Build a release APK (see the main [README](../README.md#android) for
cross-compile options), then install it over adb:

```sh
adb install -r build/app/outputs/flutter-apk/app-release.apk
```

Or copy the APK to the phone and install it from a file manager (you'll need
to allow "Install unknown apps" for that file manager once).

## Do you need any of this?

By default Quicklog writes to its app-specific external directory
(`/Android/data/org.buetow.quicklog/files/`), which needs **no storage
permission at all** — Android grants every app write access to its own
folder. If that's good enough (e.g. you point Syncthing at that exact
folder), skip the rest of this document.

You only need the steps below if you set **Preferences → Directory** to a
folder Quicklog doesn't own, such as an existing Obsidian/Syncthing vault.

## Stock Android / GrapheneOS: "All files access"

Open **Preferences**. If the directory you've chosen isn't writable, a red
"No storage access" card appears — tap it. This deep-links to the system
"All files access" toggle for Quicklog; enable it there and come back.

On GrapheneOS you'll instead see a three-way choice: **Allow (in Settings)**,
**Don't allow**, or **Setup Storage Scopes**. Plain "Allow" grants the same
broad `MANAGE_EXTERNAL_STORAGE` permission as stock Android. If you'd rather
not hand Quicklog the whole filesystem, use Storage Scopes instead — see
below.

## GrapheneOS: Storage Scopes (recommended)

[Storage Scopes](https://grapheneos.org/usage#storage-scopes) is a
GrapheneOS-specific feature that lets an app *believe* it has full storage
access while the OS actually restricts it to specific folders (or to files
the app created itself).

1. From the permission dialog described above, choose **Setup Storage
   Scopes**. This opens **Settings → Apps → Quicklog → Storage Scopes**,
   which you can also reach directly at any time.
2. You'll see **Add folder** / **Add file** / **Add image** shortcuts. In
   principle you'd use **Add folder** to browse to an existing folder and
   grant access to it — but as of GrapheneOS's current picker, browsing to
   an existing folder that already has content is unreliable (the picker
   can show "No items" at every level, even at the true storage root).

### The reliable trick: let Quicklog create its own folder

Storage Scopes always permits an app to create and use files/folders **it
created itself**, with no picker interaction needed. Quicklog relies on
exactly this:

1. Turn on Storage Scopes (step 1 above), then skip "Add folder" entirely —
   just close that screen.
2. In **Preferences → Directory**, point Quicklog at a **new, not-yet-existing**
   subfolder — e.g. use the bolt icon's *Vault/Quicklog* quick-switch entry,
   or type a fresh path like `/storage/emulated/0/Notes/Vault/Quicklog`.
   The folder must not already exist (if it does, e.g. because you created
   it by hand in a file manager, delete it first — Quicklog needs to be the
   one to create it).
3. Save, then log any entry. Quicklog creates the directory itself on first
   write, which Storage Scopes then treats as app-owned — both writing new
   entries and browsing them (**Entries** screen) keep working from then on,
   with no further prompts.

This gets you a synced-vault-friendly directory without ever granting
Quicklog broad filesystem access.

## Quick-switch directories

The bolt icon next to the Directory field in Preferences offers shortcuts to
a few common Android locations (a notes vault subfolder, `Documents`,
`Download`). Pick one, then hit the checkmark to save — no need to type full
paths by hand.
