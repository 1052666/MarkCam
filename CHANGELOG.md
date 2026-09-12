# Changelog

## 1.3.0 (7) — native camera and editor craft
- Apply Emil Kowalski's design guidance to native UIKit: immediate double-ring shutter feedback, neutral chrome, consistent selected states and 44pt camera touch targets.
- Divide the editor into Layers, Tone, Templates and Settings; route camera settings directly to its tab while retaining every original editing capability.
- Keep continuous edits responsive by updating the preview immediately and persisting on completion, cancellation, tool changes, navigation and interruption. Persist discrete VoiceOver slider changes immediately.
- Support Dynamic Type in forms, compact preview layout at accessibility sizes, opaque high-contrast/reduced-transparency chrome and reduced-motion custom feedback.
- Add actual UIKit Simulator interaction and screenshot regression on standard and compact iPhones, including landscape, large text, settings routing and persistence behavior. The scene and shutter receiver are explicit fixtures; hardware performance and image quality remain unmeasured.
- Include the shutter recovery, isolated per-photo delegates and bounded continuous capture improvements from 1.2.1.

## 1.2.1 (6) — capture recovery and responsive shooting test release
- Refresh shutter admission even when rendering is paused or memory-constrained; release the editor's queue lock on return to the camera.
- Retain a separate delegate and immutable settings per photo. Release the ordinary shutter after exposure; admit at most two in-flight photos within the six-job pending budget.
- Move JPEG writes and completion bookkeeping off main; avoid repeating exposure locks and preview reconfiguration for each shutter press.
- Add an enabled-by-default fast-capture setting, with a visible low-light quality tradeoff and an option to restore balanced quality. Keep configured photo dimensions and balanced Live capture.
- Resume transient memory and confirmed photo-permission failures without retrying uncertain PhotoKit saves. Validate recovered settings before processing; preserve incomplete recordings for explicit recovery.
- Add macOS callback runtime regression, host C admission/recovery tests, four individual negative selector compile controls, and a pinned Linux IPA build workflow. These checks do not certify iPhone camera performance or Live playback.

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
