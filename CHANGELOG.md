# Changelog

## 1.1.0 (3)
- Add native Live Photo capture with watermarks and tone on the still and motion components.
- Preserve paired identity, native timed metadata tracks and track associations; validate the output using PHLivePhoto before paired PhotoKit saving.
- Preserve original pairs on failure/cancellation and support pending-pair retry/export.
- Move EV exposure compensation to Settings, persist its value and add reset-to-zero.
- Replace the preview EV slider with camera zoom, synchronized with pinch gestures and device limits.
- Add toolbar LIVE toggle and direct Settings entry.
- Cross-build, binary/static checks and compiler regressions pass. Live playback and new UI still need device acceptance.

## 1.0.1 (2)
- Fix incorrect AVCapturePhotoCaptureDelegate selectors that caused shutter-triggered aborts in 1.0.0.
- Require photo callback implementations at compile time and inspect the packaged Mach-O method table.
- Add positive/negative compiler regression tests.
- Validate photo request state and preserve rejected-request diagnostics locally.
- Keep Bundle ID and user data schema unchanged.
- Cross-build and structural checks pass; user subsequently confirmed normal photo capture. IPA requires legitimate re-signing.

## 1.0.0 (1)
Initial native camera, tone controls, multilayer watermarks, template storage/import/export, video export and PhotoKit saving. Known shutter crash; do not use this version for photos.
