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
- Current phase: **Phase 2** (blend engine) — code complete, builds clean for simulator; **not yet run on a real device**. Phases 0–1 done: project setup, folder structure, frame extraction. `ImportService` (PHAsset → paired video → `AVAssetReader` BGRA sweep), `FrameStore` (full-res + 720px preview set), `LivePhotoPicker`, `FrameDebugWriter` (now also dumps a single blended CGImage). `BlendKernels.metal` holds the real linear-light reduction kernels (`accumulate_average/lighten/darken` + `resolve`). `BlendEngine.swift` drives them: per-frame accumulation into an rgba32Float texture, sRGB↔linear conversion, returns a `CGImage`. `ContentView.swift` is a Phase 1–2 debug screen (pick → extract → blend average/lighten/darken → preview + dump PNG). Deployment target is iOS 17.0, iPhone-only.

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
