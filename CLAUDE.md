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
- Current phase: **Phase 6** (exposure normalization) done in code. Phase 5 (registration, translation-only) **verified working on device**. Phases 0–4 (the v1 ship point: import → select → blend → export + in-app library) done in code. Everything builds clean and launches in the simulator (landing + library toolbar button verified via screenshot). The blend/export paths and the new **normalization** path are unverified in the simulator (no Live Photos) — normalization needs a real-device run.
- Phases 0–1: project setup, folder structure, frame extraction. `ImportService` (PHAsset → paired video → `AVAssetReader` BGRA sweep), `FrameStore` (full-res + 720px preview set, plus `makeThumbnails()` for the timeline), `LivePhotoPicker`, `FrameDebugWriter`.
- Phase 2: `BlendKernels.metal` holds the linear-light reduction kernels (`accumulate_average/lighten/darken` + `resolve`). `BlendEngine.swift` accumulates per-frame into an rgba32Float texture, sRGB↔linear, returns a `CGImage`. Has a range-aware `blend(frames:range:mode:)` with an LRU result cache (`invalidateCache()` on new import).
- Phase 3: `EditorViewModel` (`@Observable @MainActor`) holds selection range + mode, debounces re-blend (30ms) on the preview-res frames during drags. `TimelineStrip` is a thumbnail strip with two draggable range handles, a dimming scrim over excluded frames, and a selection border. `EditorView` = preview canvas + segmented mode picker + timeline.
- Phase 4: `ExportService` renders the selected range at full res (bypasses the preview cache to avoid key collisions; optional Standard 2048px downscale) and has a static `saveToPhotos` (`PHPhotoLibrary.performChanges`, addOnly auth). `EditorViewModel.export(saveToPhotos:)` renders → saves to the in-app library → optionally Photos. **In-app library**: `Exposure` (Codable metadata), `LibraryStore` (`@Observable @MainActor`; JPEGs in `Documents/Exposures/` + `index.json`, on-device, independent of Photos), `LibraryView` (grid + `ExposureDetailView` with share/save-to-Photos/delete), `ShareSheet` (UIActivityViewController). `ContentView`: landing → pick → `EditorView`; a `photo.stack` toolbar button (always present) opens the library sheet; "New" re-picks.
- Phase 5: registration is **translation-only** for v1 (corrects handheld shake; not rotation/tilt). The earlier homography path produced a tiling/duplicating artifact — the Vision-matrix → `CIPerspectiveTransform` corner mapping was wrong and unverifiable without a device, so it was dropped. It aligns around the **centre of the current selection**, not the whole clip — so the part of the scene being blended is what stays sharp. `RegistrationService` (Vision `VNTranslationalImageRegistrationRequest`) returns `FrameTransform.translation(dx:dy:measuredWidth:)`; `apply(_:to:using:)` **rescales** the pixel offset from the resolution it was measured at (preview ~720px) to the target buffer, applies the affine, then `.clampedToExtent().cropped(to: source.extent)` for a full-size, non-tiling output. (Rescaling matters: preview-pixel offsets must scale up for full-res export.) `FrameStore` holds only raw frames; `previewFrames(for:)` / `fullResolutionFrames(for:)` return the aligned slice for a range when `isRegistered`, reference = `lower + referenceIndex(count)`. Transforms cached per reference index (`transformCache`) — dragging the *far* handle (centre unchanged) reuses the Vision result; moving the centre recomputes. Off-actor work goes through `RegistrationService.alignedSlice`/`transformsOffActor` with a `PixelBufferBox: @unchecked Sendable` wrapper (CoreVideo `CVBuffer` isn't Sendable). `EditorViewModel`: when registration is on, blend/export bypass the engine range cache (aligned pixels vary with the selection) and call uncached `engine.blend(frames:mode:)`; when off, the cached `blend(frames:range:mode:)` path is kept for instant drag-replay. `EditorView` has an "Align frames" `Toggle` + spinner (`isRegistering`). Thumbnails always show raw frames.
- Phase 6: exposure normalization matches each frame's brightness + white balance to the selection's centre frame, killing the pulsing/banding the camera's re-metering causes. `NormalizationService` (stateless, `nonisolated`): `gains(for:reference:using:)` measures each frame's **mean linear RGB** (`CISRGBToneCurveToLinear` → `CIAreaAverage` → 1px `RGBAf` readback) and derives a per-channel `FrameGain` = `refMean / frameMean`, **clamped to 0.5–2.0** (so an exposure-jump/blown/near-black outlier can't apply an extreme multiplier; mean ≤ 0.004 → unit gain). `apply(_:to:using:)` does linearize → `CIColorMatrix` per-channel multiply → back to sRGB. `normalize(_:reference:using:)` measures + applies off-actor (same `PixelBufferBox` wrapper). Pipeline order in `FrameStore.frames(_:for:)`: slice → **register** (if on) → **normalize** (if on); normalization uses the **slice-relative** centre index since the slice is re-indexed after registration. `FrameStore.isNormalized` + `setNormalization(enabled:)`; `EditorViewModel.normalizationEnabled` (mirrors registration: invalidates engine cache, re-blends). `EditorViewModel.processesFramesPerSelection` = registration OR normalization → when either is on, blend/export bypass the engine range cache and use uncached `engine.blend(frames:mode:)`. `EditorView` groups both into an `adjustments` section via a shared `toggleRow`; "Match exposure" is the normalization toggle.
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
