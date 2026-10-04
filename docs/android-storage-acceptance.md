# Android storage acceptance

Device checks use the app UI and a locally built release APK. They complement
the Flutter tests; a mocked platform channel does not establish Android storage
behavior.

## Legacy typed paths (task n43, 2026-10-03)

Source: `a4d9504` (Quicklog 0.3.3). Built with
`flutter build apk --release --split-per-abi --no-pub` and installed the x86_64
APK: version code 183, min SDK 24, target SDK 36. Its SHA-256 is
`d538edcff2a45ffa399fe32863c014d83cc117f733ee3d042b09d0ebe7426786`.
This is a local acceptance build, not a reproducibility or publication check.

Android Emulator 33.1.24 ran the AOSP default x86_64 images with KVM,
SwiftShader graphics, and a cold boot. API 28 image revision 4 reported:

```
Android/sdk_phone_x86_64/generic_x86_64:9/PSR1.180720.012/4923214:userdebug/test-keys
```

API 29 image revision 8 reported:

```
Android/sdk_phone_x86_64/generic_x86_64:10/QSR1.210820.001/7663313:userdebug/test-keys
```

| Check | Android 9 / API 28 | Android 10 / API 29 |
| --- | --- | --- |
| Fresh default directory: create note without a storage prompt | Passed | Passed |
| Download: warning opens the runtime Storage permission dialog | Passed | Passed |
| Deny permission: warning remains and permission can be requested again | Passed | Passed |
| Grant permission: Download create/list/read/edit/delete | Passed | Passed |
| Documents create/list/read/edit/delete | Passed | Passed |
| Missing Notes/Vault/Quicklog path: create directories and CRUD | Passed | Passed |
| Cancel deletion: note remains | Passed for all three custom paths | Passed for all three custom paths |

Each custom path was chosen through Preferences' Directory quick switch,
which saves a filesystem path rather than an Android picker URI. A note was
written using **Log text**, listed through **Browse entries**, opened in the
viewer, edited and saved, then deleted through its confirmation screen.
Screenshots were inspected for the warning, listing, and saved edit; adb also
checked the Markdown contents on disk and removal after deletion. The initial
Download deletion checked the empty listing; later path cycles additionally
checked that the file was absent on disk. Permission denial did not select
"Don't ask again".

On API 29, `dumpsys package` showed both READ/WRITE_EXTERNAL_STORAGE denied
before the default write and granted after the runtime dialog. `cmd appops get
org.buetow.quicklog LEGACY_STORAGE` reported `allow`. The actual shared-path
writes above establish legacy-mode behavior for this target-SDK-36 APK on this
Android 10 image; the manifest flag alone was not treated as proof.

Local verification at the same source revision: `flutter analyze --no-pub`
passed, `flutter test --no-pub` passed all 566 tests, and the split release build
passed for armeabi-v7a, arm64-v8a, and x86_64.

These checks cover typed paths on the two named images. The broader task o43
also requires API 34, persisted picker grants, revoked grants, sharing, and
Local + S3 failure behavior; those are not established by this table.

## Full storage matrix (task o43, 2026-10-03–04)

The broader check found and fixed an Android 9 picker-path failure. Its AOSP
external-storage provider moves a document before looking up the old path for a
media-store update, which can throw `FileNotFoundException` after the rename.
See [Android 9 FileSystemProvider](https://github.com/aosp-mirror/platform_frameworks_base/blob/android-9.0.0_r1/core/java/com/android/internal/content/FileSystemProvider.java).
An initial create could therefore report failure after publishing the file;
an edit left the original under a backup name and the replacement staged.
Those bytes were preserved, but listing and re-selection could fail during
recovery. This was a real API 28 device result, not a mocked channel result.

The workaround is enabled only for API 28's
`com.android.externalstorage.documents` provider. When a rename throws for a
missing file, it accepts a newly listed unique target only if the old document
ID disappeared, the target ID was absent before the operation, and the contents
match the original. IDs remain opaque. Other providers keep their existing
failure behavior. Native regressions cover successful move-then-throw, failure
without moving, corrupt bytes, duplicate targets, and ordinary providers.

The refreshed x86_64 release APK still reports Quicklog 0.3.3, version code 183,
target SDK 36. It was built from `81130ff` plus this workaround; SHA-256:
`505b31490ef39de3c30108c6c7cb4544aa5bb875e7c81992360771c624b7ade7`.
The API 28 and 29 images are identified above. API 34 uses a separate disposable
Google APIs x86_64 revision 8 AVD, fingerprint
`google/sdk_gphone64_x86_64/emu64xa:14/UE1A.230829.036.A1/11228894:userdebug/dev-keys`,
so Player's existing emulator was not altered.

| Check | API 28 | API 29 | API 34 |
| --- | --- | --- | --- |
| Default-folder CRUD without broad storage permission | Passed | Passed | Passed |
| Typed Download/Documents/vault CRUD and OS-specific permission flow | Passed in n43 | Passed in n43 | Passed; see access distinction below |
| Pick existing vault, force-stop/relaunch, then CRUD | Passed after fix | Passed | Passed |
| Cancel deletion and preserve an unrelated vault file | Passed | Passed | Passed |
| Share text through ShareActivity, then save in picked vault | Passed | Passed | Passed |
| Local + S3 connection failure keeps note in picked vault | Passed | Passed | Passed |
| Revoked picker grant: warning, list error, write error, retained draft | Passed | Passed | Passed |
| Re-select vault and save retained draft | Passed | Passed | Passed |

On API 34, a typed Download path accepted a new note with All files access
ungranted, but an adb-placed existing note was absent from the browser. Granting
All files access made that existing note visible and editable. A successful
write probe therefore does not establish access to notes created outside
Quicklog. To exercise the app's Settings route, a deliberately unwritable
`/data/local/tmp/QuicklogAcceptance` path triggered the access card; tapping it
opened Quicklog's All files access screen. That protected path is not claimed
writable after granting access. The subsequent typed-path checks used normal
shared directories. The installation guide explains how to open All files
access manually when a successful write probe hides the card.

Picker checks revoke broad storage permission first. The selected vault is
`Notes/Vault/Quicklog`, contains an unrelated sentinel file, and is reached
through DocumentsUI. The app's persisted grant and selection survive force-stop
and relaunch. Share testing launches the exported text/plain ShareActivity with
a disposable marker, verifies prefill, then presses **Log text**; the separate
auto-log preference is outside this check.

The Local + S3 outage uses dummy credentials and `http://10.0.2.2:1`, which
refuses the connection. The app displays its local-save/outage message, clears
the submitted draft, and the actual Markdown file contains the marker in the
picked vault. This checks failure fallback, not successful remote upload.

For revocation, on each dedicated rooted emulator, stop the Android framework,
remove only Quicklog's persisted tree grant from `/data/system/urigrants.xml`,
retain its owner/mode/SELinux context, and restart the framework. API 34 uses
Android's `abx2xml`/`xml2abx` tools to preserve its binary XML format. App preferences
and notes remain in place. Verify the unavailable-folder warning, the browser's
expired-access error, and a failed write retaining its draft. Re-select the
same vault and save that retained draft. Existing shared/fallback files remain
intact. This induces actual OS permission loss, not a fake service response.

The original historical APK was not rebuilt. On API 29 the current baseline
APK reproduced a typed Download write permission error with READ/WRITE denied,
and retained the draft; granting permission or selecting a picker folder
restored access. The earlier n43 checks cover the corrected legacy-path flow.

Verification after the workaround: `flutter analyze --no-pub` clean,
`flutter test --no-pub` 566 passed, native `:quicklog_platform:testDebugUnitTest`
26 passed, and split release APK builds passed for all three ABIs.
README storage guidance now distinguishes picker grants, Android 7–10 Storage
permission, and Android 11+ All files access. The installation guide and store
description were also clarified against the measured Android 14 behavior.

Results apply to these emulator images and their document providers. Physical
devices, Android 7/8 individually, GrapheneOS Storage Scopes, removable volumes,
and third-party document providers were not tested.
