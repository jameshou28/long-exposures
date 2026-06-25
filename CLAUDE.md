# long-exposures

iOS app that turns Live Photos and videos into custom long exposures. The user selects which frames blend. See `IMPLEMENTATION-PLAN.md` for the full phased plan.

## Target

- iOS 17+, iPhone only for v1.
- Swift, SwiftUI, Metal.
- No backend. No third-party packages. System frameworks only.
- On-device processing is a selling point — keep it that way.

## Frameworks

- **PhotoKit** — access Live Photos and videos.
- **AVFoundation** — decode video to frames; locked capture in Phase 7.
- **Vision** — frame registration (`VNHomographicImageRegistrationRequest`, `VNTranslationalImageRegistrationRequest`).
- **Metal / MPS** — blend engine compute shaders.
- **Core Image** — transform application, color conversion.

## Architecture

Keep these as separate types. Pipeline is data in, image out. UI drives it.

- `ImportService` — PhotoKit access; pulls frames into pixel buffers.
- `FrameStore` — full-res frames + downsampled preview set.
- `RegistrationService` — Vision alignment; returns transforms.
- `NormalizationService` — per-frame brightness + white balance matching.
- `BlendEngine` — Metal compute; takes frame selection + mode, returns composite.
- `EditorViewModel` — selection state, blend mode, toggles; drives preview.
- SwiftUI views — timeline, preview canvas, controls.

Folder structure: `Engine/`, `Services/`, `Views/`, `Models/`.

## Pipeline order (always)

```
Import → Register → Normalize → Select → Blend → Export
```

- Register before normalize — alignment uses feature matching that brightness shifts disrupt.
- Normalize before blend — blending bad exposures bakes in artifacts.
- Select before blend — user picks from cleaned, aligned frames.

## Build rules

- **Engine before UI.** Verify the blend engine by writing output to disk with no interface.
- **Phases are sequential.** Do not skip ahead. Later phases depend on earlier ones.
- **Each phase ends with something runnable.** After each phase, build and run on a real device before continuing.
- Current phase: **Phase 8** (polish/ship) in progress — **before/after compare** done in code. (A focus-frame feature was built then scrapped — an opaque overlay covered everything, and the Vision-masked version wasn't wanted; all of it was removed.) Phase 7 (in-app capture) done in code. Phase 6 (exposure normalization) done in code. Phase 5 (registration, translation-only) **verified working on device**. Phases 0–4 (the v1 ship point: import → select → blend → export + in-app library) done in code. Everything builds clean and launches in the simulator (landing screen with **Pick Live Photo + Capture** buttons verified via screenshot). The blend/export, **normalization**, and **capture** paths are unverified in the simulator (no Live Photos, no camera) — capture especially needs a real-device run.
- Phases 0–1: project setup, folder structure, frame extraction. `ImportService` (PHAsset → paired video → `AVAssetReader` BGRA sweep), `FrameStore` (full-res + 720px preview set, plus `makeThumbnails()` for the timeline), `LivePhotoPicker`, `FrameDebugWriter`.
- **Sources**: import accepts both **Live Photos and regular videos**. `LivePhotoPicker` filters `.any(of: [.livePhotos, .videos])` and returns a `PickedItem` enum — `.livePhoto(identifier:)` (resolved via PhotoKit to the paired video) or `.video(url:)` (the file copied out of the `itemProvider` to a temp URL, since the provider's URL is only valid in the completion handler). `ContentView.handlePicked(_:)` branches on the enum; both feed the same `extractFrames` → `ingest` → `makeEditor()` tail. Long videos are **sampled evenly down to `ImportService.maxFrames = 120`**: `sampleStride(for:track:)` estimates total frames from `duration × nominalFrameRate` and keeps every Nth during the reader sweep (stride 1 for short clips), so memory + the timeline stay bounded regardless of clip length. Landing button: "Pick Live Photo or Video".
- **Temp-file hygiene**: import writes a video into `tmp/` (PhotoKit `writeData` for Live Photos; `itemProvider` copy for picked videos). These are deleted right after decoding — `extractFrames(from asset:)` cleans up via `defer`, and `ContentView.handlePicked`'s `.video` case `defer`s `ImportService.removeTempFile(url)` (which only deletes inside the temp dir). `ImportService.purgeTempVideos()` runs in `long_exposuresApp.init()` to reclaim leftovers from earlier/crashed runs (sweeps `tmp/` for `mov/mp4/m4v`). Was the cause of a large "Documents and Data" figure — orphaned temp videos, not the library. Verified on the sim: a seeded 20MB `tmp/*.mov` is gone after relaunch. The library itself (`Documents/Exposures/`) is one JPEG (quality 0.95) per saved exposure + `index.json`.
- Phase 2: `BlendKernels.metal` holds the linear-light reduction kernels (`accumulate_average/lighten/darken` + `resolve`). `BlendEngine.swift` accumulates per-frame into an rgba32Float texture, sRGB↔linear, returns a `CGImage`. Has a range-aware `blend(frames:range:mode:)` with an LRU result cache (`invalidateCache()` on new import).
- Phase 3: `EditorViewModel` (`@Observable @MainActor`) holds selection range + mode, debounces re-blend (30ms) on the preview-res frames during drags. `TimelineStrip` is a thumbnail strip with two draggable range handles, a dimming scrim over excluded frames, and a selection border. `EditorView` = preview canvas + segmented mode picker + timeline.
- Phase 4: `ExportService` renders the selected range at full res (bypasses the preview cache to avoid key collisions; optional Standard 2048px downscale) and has a static `saveToPhotos` (`PHPhotoLibrary.performChanges`, addOnly auth). `EditorViewModel.export(saveToPhotos:)` renders → saves to the in-app library → optionally Photos. **In-app library**: `Exposure` (Codable metadata), `LibraryStore` (`@Observable @MainActor`; JPEGs in `Documents/Exposures/` + `index.json`, on-device, independent of Photos), `LibraryView` (grid + `ExposureDetailView` with share/save-to-Photos/delete), `ShareSheet` (UIActivityViewController). `ContentView`: landing → pick → `EditorView`; a `photo.stack` toolbar button (always present) opens the library sheet; "New" re-picks.
- Phase 5: registration is **translation-only** for v1 (corrects handheld shake; not rotation/tilt). The earlier homography path produced a tiling/duplicating artifact — the Vision-matrix → `CIPerspectiveTransform` corner mapping was wrong and unverifiable without a device, so it was dropped. It aligns around the **centre of the current selection**, not the whole clip — so the part of the scene being blended is what stays sharp. `RegistrationService` (Vision `VNTranslationalImageRegistrationRequest`) returns `FrameTransform.translation(dx:dy:measuredWidth:)`; `apply(_:to:using:)` **rescales** the pixel offset from the resolution it was measured at (preview ~720px) to the target buffer, applies the affine, then `.clampedToExtent().cropped(to: source.extent)` for a full-size, non-tiling output. (Rescaling matters: preview-pixel offsets must scale up for full-res export.) `FrameStore` holds only raw frames; `previewFrames(for:)` / `fullResolutionFrames(for:)` return the aligned slice for a range when `isRegistered`, reference = `lower + referenceIndex(count)`. Transforms cached per reference index (`transformCache`) — dragging the *far* handle (centre unchanged) reuses the Vision result; moving the centre recomputes. Off-actor work goes through `RegistrationService.alignedSlice`/`transformsOffActor` with a `PixelBufferBox: @unchecked Sendable` wrapper (CoreVideo `CVBuffer` isn't Sendable). `EditorViewModel`: when registration is on, blend/export bypass the engine range cache (aligned pixels vary with the selection) and call uncached `engine.blend(frames:mode:)`; when off, the cached `blend(frames:range:mode:)` path is kept for instant drag-replay. `EditorView` has an "Align frames" `Toggle` + spinner (`isRegistering`). Thumbnails always show raw frames.
- Phase 6: exposure normalization matches each frame's brightness + white balance to the selection's centre frame, killing the pulsing/banding the camera's re-metering causes. `NormalizationService` (stateless, `nonisolated`): `gains(for:reference:using:)` measures each frame's **mean linear RGB** (`CISRGBToneCurveToLinear` → `CIAreaAverage` → 1px `RGBAf` readback) and derives a per-channel `FrameGain` = `refMean / frameMean`, **clamped to 0.5–2.0** (so an exposure-jump/blown/near-black outlier can't apply an extreme multiplier; mean ≤ 0.004 → unit gain). `apply(_:to:using:)` does linearize → `CIColorMatrix` per-channel multiply → back to sRGB. `normalize(_:reference:using:)` measures + applies off-actor (same `PixelBufferBox` wrapper). Pipeline order in `FrameStore.frames(_:for:)`: slice → **register** (if on) → **normalize** (if on); normalization uses the **slice-relative** centre index since the slice is re-indexed after registration. `FrameStore.isNormalized` + `setNormalization(enabled:)`; `EditorViewModel.normalizationEnabled` (mirrors registration: invalidates engine cache, re-blends). `EditorViewModel.processesFramesPerSelection` = registration OR normalization → when either is on, blend/export bypass the engine range cache and use uncached `engine.blend(frames:mode:)`. `EditorView` groups both into an `adjustments` section via a shared `toggleRow`; "Match exposure" is the normalization toggle.
- Phase 7: in-app capture with **locked exposure + white balance** (locked capture yields consistent frames, sidestepping normalization). `CaptureService` (`@Observable @MainActor`) is the UI face (`state` idle/recording/finished, `capturedFrameCount`, `errorMessage`, `session` accessor, `requestAuthorization`, `configure`, `startRecording`, async `stopRecording`). The actual `AVCaptureSession` + non-Sendable objects live in a private `SessionController: @unchecked Sendable` that confines **all** access to one serial `sessionQueue` (this is what keeps the concurrency clean — don't touch the session/output/device off that queue). Back `builtInWideAngleCamera` + `AVCaptureVideoDataOutput` (BGRA); `lockExposureAndWhiteBalance()` sets `.custom` exposure (current duration/ISO) + `.locked` WB on record. A `FrameCollector` delegate appends frames on the queue; each is `deepCopyBGRA()`-ed out of the output's reuse pool. Frames feed the **same `FrameStore.ingest`** as import — pipeline downstream is identical. `CapturePreview` = `UIViewRepresentable` over `AVCaptureVideoPreviewLayer`. `CaptureView` = full-screen live preview + shutter-style record button (`fullScreenCover`). `ContentView`: landing has **Pick Live Photo** + **Capture** buttons; `beginCapture()` checks camera auth then presents; `handleCapturedFrames` ingests → `makeEditor()` (shared helper, also used by the import path). Needs a real device (no camera in sim). `NSCameraUsageDescription` present in pbxproj (both configs).
- Phase 8 (so far): **before/after compare**. Hold the preview → `EditorViewModel.isComparing` swaps the shown image to a single sharp frame (`compareImage` = the selection's centre frame, rendered via `BlendEngine.render(frame:)` which is a one-frame average through the same Metal pipeline as the blend) without re-blending; `blendedImage`/`compareImage` are cached so it's instant. `EditorView.previewCanvas` has the hold-to-compare `DragGesture(minimumDistance:0)` + an "Original frame" badge. (A focus-frame feature was prototyped — pick one frame to stay crisp over the blur — then **scrapped**: an opaque overlay covered the whole image, and the Vision-foreground-mask version, `SubjectMaskService` + `composite(focusFrame:mask:over:)`, wasn't wanted. All focus code, the mask service, and the `composite` method were removed; `render(frame:)` stayed because compare uses it.)
- Phase 8 (so far): **settings + permission priming**. `AppSettings` (`@Observable @MainActor`, UserDefaults-backed) holds `defaultMode`/`defaultResolution`; `BlendMode` and `ExportResolution` are now `String, CaseIterable` (raw values persist) with `displayName` extensions. `SettingsView` (Form, gear toolbar button on the landing screen — only when not editing) edits the defaults + an "On device / no data" About section. `EditorViewModel.init(...,settings:)` seeds `mode`/`exportResolution` from them so a fresh import opens on the user's preferences. **Permission priming**: `PermissionPriming` (sheet, `.medium` detent, `Kind` = `.photos`/`.camera`) explains *why* before the cold system prompt. `ContentView.beginPick`/`beginCapture` check `PHPhotoLibrary.authorizationStatus(for: .readWrite)` / `AVCaptureDevice.authorizationStatus(for: .video)` == `.notDetermined` → show priming first (`primingFor`), then `proceedAfterPriming` → `requestAndPick`/`requestAndCapture` fires the real prompt; if already decided, proceeds straight through. **NOT visually verified** (sim can't tap-inject; Settings/Priming sheets compile + the gear button renders, but the sheet contents are unconfirmed on a device).
- **Still TODO in Phase 8**: per-frame include/exclude, reference-frame picker, onboarding, empty state, + App Store prep.
- Deployment target is iOS 17.0, iPhone-only.

## Blend engine specifics (Phase 2 — the technical heart)

- Compute shader that reduces over N frames.
- Convert sRGB → linear light **before** accumulating. Blending in gamma space causes artifacts.
- Accumulate in a float texture to avoid clipping.
- Convert back to sRGB on output.
- Modes: `average` (motion blur), `lighten` / max (light trails), `darken` / min (niche). Implement average first.

## Preview performance (Phase 3)

- Blend at preview resolution during interaction; full-res only on export.
- Cache partial results. If only the end handle moves, do not re-blend frames that did not change.
- Use `AVAssetReader` + `AVAssetReaderTrackOutput` to decode every frame. Do **not** use `AVAssetImageGenerator` for a full sweep.
- Output pixel format: `kCVPixelFormatType_32BGRA`.

## Registration specifics (Phase 5)

- Reference = middle frame (least cumulative drift).
- Find transform on downsampled frames for speed; apply to full-res with Core Image `transformed(by:)`.
- Registration fixes the static background. Moving subjects stay blurred — that is correct.
- Fall back to translation-only when homography fails (low texture, heavy blur).

## Info.plist

- `NSPhotoLibraryUsageDescription` — required.
- `NSCameraUsageDescription` — for Phase 7 capture.

## Code style

- 4-space indentation, PascalCase types, camelCase properties/methods.
- `@State private var` for SwiftUI state; `let` for constants.
- Prefer `async`/`await` over Combine.
- Avoid force unwrapping. Lean on Swift's type system.
- Comments only when the *why* is non-obvious.

## Validating work

Prefer in this order: `XcodeRefreshCodeIssuesInFile` for fast diagnostics → `ExecuteSnippet` for trying ideas → `BuildProject` for full builds. Don't claim something works without running it.

## The three hard parts (budget extra time)

1. Metal blend engine — reduction over N frames in linear light with selectable mode.
2. Preview performance — preview-res blending + partial-result caching.
3. Selection UX — easy to make confusing. Prototype in isolation.
