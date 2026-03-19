# OpenPhotos Android (Java) — Developer Guide

- Min SDK: 30, Target/Compile: 34
- Code: Java (Kotlin libs allowed)
- Build: `./gradlew :app:assembleDebug`
- Release APK helper: `../scripts/build_android_installer.sh`

## Modules
- Auth: `ca.openphotos.android.core.AuthManager`, `AuthorizedHttpClient`, `CapabilitiesService`
- DB: `ca.openphotos.android.data.db.*` (Room)
- Media: `MediaStoreScanner`, `Transforms`, `MotionPhotoParser`, `AlbumPathUtil`
- Upload: `TusUploadManager` (foreground), `BackgroundTusWorker` + `UploadScheduler` (background), `UploadOrchestrator`
- E2EE: `E2EEManager`, `PAE3`, `CryptoAPI`, `DeviceUMKStore`, `DecryptedCache`
- Prefs: `SyncPreferences`, `SecurityPreferences`

## Permissions
- INTERNET, POST_NOTIFICATIONS, ACCESS_MEDIA_LOCATION

## Background Uploads
- Uses WorkManager + ForegroundService (persistent "Uploading…" notification)
- Wi‑Fi-only and per-media cellular policies via `SyncPreferences`

## E2EE
- Envelope: `/api/crypto/envelope`
- PAE3 v3: orig + thumb
- UMK quick unlock: Android Keystore (biometric user auth)

## Notes
- Motion Photos: basic extraction for Pixel/Samsung (best-effort)
- RAW thumbnails: embedded preview or decoded sample

## Release APK
- Canonical packaging script: `../scripts/build_android_installer.sh`
- The helper always produces an installable release APK
- Signing behavior:
  - uses the provided `ANDROID_KEYSTORE_*` env vars when present
  - otherwise auto-generates and reuses `android-java/.openphotos-signing/openphotos-auto-release.jks`
- SDK discovery:
  - uses `ANDROID_HOME` or `ANDROID_SDK_ROOT` when set
  - otherwise tries common SDK locations and writes `android-java/local.properties` automatically
- Output artifact:
  - `../dist/android-packages/openphotos-android-release.apk`
- Important:
  - back up `android-java/.openphotos-signing/openphotos-auto-release.jks`
  - future app updates must use the same signing key
  - this helper intentionally does not produce unsigned APKs

Required environment variables for signed release builds:
- `ANDROID_KEYSTORE_PATH`
- `ANDROID_KEYSTORE_PASSWORD`
- `ANDROID_KEY_ALIAS`
- `ANDROID_KEY_PASSWORD`

Example:
```bash
export ANDROID_KEYSTORE_PATH=/absolute/path/to/release.keystore
export ANDROID_KEYSTORE_PASSWORD=...
export ANDROID_KEY_ALIAS=...
export ANDROID_KEY_PASSWORD=...

../scripts/build_android_installer.sh
```

Without signing env vars, the script auto-generates and reuses a local release keystore:
```bash
../scripts/build_android_installer.sh
```

Generated local keystore path:
```bash
android-java/.openphotos-signing/openphotos-auto-release.jks
```

To reuse an existing signed release APK without rebuilding:
```bash
../scripts/build_android_installer.sh --no-build
```
