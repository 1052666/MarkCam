# Changelog

## 1.0.1 (2)
- Fix incorrect AVCapturePhotoCaptureDelegate selectors that caused shutter-triggered aborts in 1.0.0.
- Require photo callback implementations at compile time and inspect the packaged Mach-O method table.
- Add positive/negative compiler regression tests.
- Validate photo request state and preserve rejected-request diagnostics locally.
- Keep Bundle ID and user data schema unchanged.
- Cross-build and structural checks pass; device retest is pending. IPA requires legitimate re-signing.

## 1.0.0 (1)
Initial native camera, tone controls, multilayer watermarks, template storage/import/export, video export and PhotoKit saving. Known shutter crash; do not use this version for photos.
