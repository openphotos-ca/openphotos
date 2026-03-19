# Known Limitations

- Server UI is minimal: album listing, faces count, and search stub are provided; create/update/move, faces assignment, media detail/edit, rating, and lock/unlock UIs are pending.
- Motion Photo extraction uses heuristics for Pixel and Samsung; other OEM formats may require enhancements.
- Argon2id is wired via LazySodium; ensure JNI libs are available on all target ABIs.
- PAE3 decrypt validates header and chunk integrity but trailer verification is simplified; tighten during interop testing.
- Background uploads rely on WorkManager; device OEM restrictions may require whitelisting from battery optimizations.

