# Installing Quicklog and setting up a custom log directory

## Installing the APK

The easiest way is F-Droid: add snonux's repository from
[snonux/fdroid](https://github.com/snonux/fdroid) (one-tap link and QR code
there) and install Quicklog from it; F-Droid then keeps it updated. See the
main [README](../README.md#install-on-android) for the address and
fingerprint.

To build it yourself instead, build a release APK (see the main [README](../README.md#android) for
cross-compile options), then install it over adb:

```sh
adb install -r build/app/outputs/flutter-apk/app-release.apk
```

Or copy the APK to the phone and install it from a file manager (you'll need
to allow "Install unknown apps" for that file manager once).

Switching between a self-built APK and the F-Droid build means uninstalling
first (they are signed with different keys), and that wipes Quicklog's
settings and its default notes folder. Before uninstalling, use
**Preferences → Export settings** and copy your notes out; after installing,
**Import settings**. See
[Back up and restore settings](../README.md#back-up-and-restore-settings).

## Do you need any of this?

By default Quicklog writes to its app-specific external directory
(`/Android/data/org.buetow.quicklog/files/`), which needs **no storage
permission at all** — Android grants every app write access to its own
folder. If that's good enough (e.g. you point Syncthing at that exact
folder), skip the rest of this document.

For an existing vault, tap **Preferences → Choose folder with Android picker**
and select the folder. Android grants Quicklog access to that folder alone;
no broad storage permission is needed. The selected folder is used for local
notes, Local + S3, and S3 failure copies. It also appears in the entry browser.
If Android revokes access, Preferences shows a warning; select it again there.
Selecting a typed path or resetting to default switches away from the picked
folder. Notes are not moved when you switch.

The steps below are for the **typed Directory path** option, which remains
useful for paths the Android picker cannot expose and for automatic creation
of a new folder. On Android 11+, an existing shared folder reached by a typed
path may require All files access.

Settings exports do not include the selected folder URI or its Android grant.
After importing an export made with a scoped folder, select that folder again;
until then Quicklog uses its app-specific default folder. Notes themselves are
never included in settings exports.

## Android 7–10: Storage permission

For a custom directory on Android 7, 8, 9, or 10, save the directory and reopen
Preferences. Tap the red **Cannot write to this folder** card, if shown, and
allow the Storage permission prompt.
Quicklog only asks when the selected directory fails a real write check; its
default app-specific folder needs no permission. Android 10 also needs the
app's legacy storage mode to use typed paths in shared folders such as
`Documents` and `Download`.

If no prompt appears, open **Settings → Apps → Quicklog → Permissions** and
allow Storage there. Return to Quicklog and recheck the directory. If the card
remains, check that the path exists or can be created and is writable; the
default app-specific directory is available from the reset button.

## Android 11 and later: "All files access"

Open **Preferences**. If the directory you've chosen isn't writable, a red
"Cannot write to this folder" card appears — tap it. This opens the system
"All files access" toggle for Quicklog; enable it there and come back.

Android may allow Quicklog to create and read its own notes in a shared folder
without that toggle, while hiding notes created outside Quicklog. A successful
write check does not establish access to every existing note. For an existing
vault, use the Android folder picker. If you prefer a typed path and existing
notes are missing, open **Settings → Apps → Special app access → All files
access → Quicklog** and enable access there, even if no red card appears.
All files access does not make Android's protected system or other apps'
private directories writable.

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

## Optional S3 mode

If you want notes to land in an S3-compatible bucket (for example Garage)
instead of a local folder:

1. Open **Preferences** and choose **S3 only**. This mode keeps no notes on
   the device: every note already in the local folder is uploaded to the
   bucket and then deleted locally (also from other devices if the folder is
   shared, e.g. with Syncthing). Choose **Local + S3** to keep local copies.
2. Fill endpoint, region, bucket, access key, and secret. Defaults target
   Garage (`https://garage.f3s.buetow.org`, region `garage`, bucket
   `quicklog`). Paste keys from a laptop copy of
   `~/.config/garage/quicklog.env` — the phone never reads that file itself.
3. **Test connection** probes without saving. Tap the checkmark (**Save**) to
   persist credentials on-device.
4. Log a note as usual. Objects are named `ql-YYMMDD-HHMMSS.md`, same as local
   files.

While mode stays **Local only**, the app does not use the network. If the
S3 write fails after you enable it, the note is written to the configured
local directory on the spot (you are told it was saved on this device), and
Quicklog keeps using that directory for new notes for about an hour (or until
**Retry S3** / a cold start). Choose **Local + S3** instead to write every
note to both the local directory and the bucket; an S3 outage still keeps
notes safe on device. To pull phone notes onto a laptop, use the drain CLI
documented in the
[README](../README.md#drain-cli-laptop).
