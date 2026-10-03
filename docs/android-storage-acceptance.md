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
