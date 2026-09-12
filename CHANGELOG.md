# Changelog

## 1.2.1 (6)
- Capture and persist the first photo before requesting PhotoKit add-only authorization.
- Release worker capture ownership after returning from the watermark editor and restarting the session.
- Refresh shutter admission during pressure/thermal/memory recovery even when the worker cannot dispatch a job; show backpressure in the camera UI.
- Share mode-aware admission between shutter UI, capture entry and countdown completion; ignore the saved LIVE preference while recording video.
- Keep video journals in `capturing` until recording has finished and the `raw` journal is written.
- Reject malformed recovery JSON before keyed access; refresh the list after an incomplete capture.
- Migrate stale queue/renderer assertions, add capture recovery checks, and build verified IPA artifacts in CI.
- No iOS device or simulator validation claimed.

## 1.2.0 (5) — early test release
- Persist capture resources and job metadata before releasing the shutter; move watermark/tone rendering and PhotoKit saving into a serial utility queue.
- Bound pending work (ordinary photos: 6; Live capture requires fewer than 2 pending jobs). Defer worker startup after capture, and prevent new capture during heavy Live/video processing.
- Add file-based Core Image photo rendering, a 2048px overlay canvas cap, available-memory checks, cache clearing, and thermal/memory-pressure backpressure. Actual memory savings are not measured.
- Preserve pending resources for pause, interruption and failure recovery; require review before retrying uncertain PhotoKit saves.
- Retain short iOS background leases only; this is not unlimited background execution or a guarantee against system jetsam.
- Cross-build succeeded. Full v1.2.0 regression is INCOMPLETE: last validation stopped at `Live resource saved as pairedVideo`; the remaining chained run was cancelled. Device acceptance has not been performed.
- Publish the exact previously delivered IPA unchanged, alongside current source and an explicit test-status report.

## 1.1.1 (4)
- Remove the 20fps preview gate and two per-frame UIImage conversions. Neutral tone uses native preview; active tone renders directly to a bounded Metal pipeline.
- Render/cache watermark overlays off the main thread. Capture the editor background only on demand.
- Add an explicit smooth-preview preference, preserving tone and watermark in captured outputs.
- Enlarge preview to available full width without stretch/crop; relocate controls to the bottom or landscape right side.
- Select rear triple/dual-wide virtual cameras when present, mapping hardware switch-over factors to true ultrawide and main-camera display zoom.
- Synchronize lens buttons, slider and pinch; coalesce rapid requests and preserve zoom through mode/front-back switches.
- Host C layout/zoom and static/binary/compiler regressions pass. Actual GPU orientation, camera performance and ultrawide Live/video require device acceptance.

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
