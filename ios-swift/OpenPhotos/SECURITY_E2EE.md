End-to-End Encryption (iOS) — Setup Guide

This app implements locked uploads using a v3 AES-GCM container (PAE3) interoperable with the web client. To enable password-based wrap/unlock of the UMK (Argon2id → HKDF), add the Sodium package so Argon2id is available on iOS.

1) Add Sodium (Swift Package Manager)

- In Xcode: File → Add Packages…
- Enter package URL: https://github.com/jedisct1/swift-sodium
- Choose a recent stable version (e.g., 0.9.x)
- Add the library to the iOS app target (OpenPhotos)

The code uses `#if canImport(Sodium)` guards. If Sodium is not present, password wrap/unlock will report a clear error. Quick unlock (device-wrapped UMK via Keychain + Face/Touch ID) works without Sodium.

2) Argon2id parameters

- The Security screen (Settings → End-to-End Encryption) lets you set Argon2id parameters: memory (MiB), time ops, and parallelism. Defaults mirror the web (m=128 MiB, t=3, p=1).
- Sodium expects `memLimit` in bytes. The implementation multiplies MiB by 1,048,576 to match web behavior.
- PWK = HKDF-SHA256( Argon2id(password, salt, m,t,p), info="umk-wrap:v1", L=32 )

3) UMK and envelopes

- Generate a new 32-byte UMK locally.
- Optionally store UMK in the device Keychain with user presence (biometric quick unlock).
- Wrap UMK under password (Argon2id) and save the envelope locally. You can push/pull the envelope to/from the server at `/api/crypto/envelope`.

4) Locked uploads

- Albums marked “Locked” cause contained assets to be encrypted client-side before upload.
- For images, HEIC is converted to JPEG before encryption (as required).
- Thumbnails (image/video) are generated client-side and encrypted as separate PAE3 files.
- TUS Upload-Metadata includes: `locked=1`, `crypto_version=3`, `kind=orig|thumb`, `asset_id_b58`, `capture_ymd`, `size_kb`, `width`, `height`, `orientation`, `is_video`, `duration_s`, `mime_hint`, and optional caption/description/location.

5) Unlock at sync time

- If UMK is not in memory, the app first attempts a biometric quick unlock. If that fails and a local envelope exists, it presents a password prompt to unlock UMK from the envelope.

6) Validate interop

- Encrypt on iOS and view/decrypt on the web client (and vice versa). Trailer HMAC and `asset_id` checks should pass.

