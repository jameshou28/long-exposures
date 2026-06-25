# Long Exposure App: Implementation Plan

A plan for Claude Code to build a free iOS app that turns Live Photos and videos into custom long exposures. The user selects which frames blend.

## How to use this document

- Build in phases. Each phase ends with something runnable.
- Do not skip ahead. Later phases depend on earlier ones working.
- After each phase, build and run on a real device before continuing.
- Keep the engine separate from the UI. Test the engine with no UI first.

## Target

- iOS 17+.
- iPhone only for v1.
- Swift, SwiftUI, Metal.
- No backend. No third-party packages. System frameworks only.

## Frameworks

- PhotoKit: access Live Photos and videos.
- AVFoundation: decode video to frames, locked capture.
- Vision: frame registration.
- Metal / Metal Performance Shaders: blend engine.
- Core Image: transform application, color conversion.

## Architecture

Keep these as separate types. The pipeline is data in, image out. The UI drives it.

- `ImportService`: PhotoKit access. Pulls frames into pixel buffers.
- `FrameStore`: holds full-res frames plus a downsampled preview set.
- `RegistrationService`: Vision alignment. Returns transforms.
- `NormalizationService`: per-frame brightness and white balance matching.
- `BlendEngine`: Metal compute. Takes a frame selection plus mode, returns a composite.
- `EditorViewModel`: selection state, blend mode, toggles. Drives preview.
- SwiftUI views: timeline, preview canvas, controls.

Build order rule: engine before UI. You can verify the engine by writing output to disk with no interface.

---

## Phase 0: Project setup

Goal: a blank project that builds and requests photo access.

Tasks:

- Create a SwiftUI iOS app project. iOS 17 deployment target.
- Add `NSPhotoLibraryUsageDescription` to Info.plist.
- Add `NSCameraUsageDescription` for later capture work.
- Create the folder structure: `Engine/`, `Services/`, `Views/`, `Models/`.
- Add a placeholder Metal file so the Metal toolchain is wired.

Done when: app launches and shows an empty screen.

---

## Phase 1: Frame extraction

Goal: pull frames out of a Live Photo and confirm them on disk.

Key APIs:

- `PHPickerViewController` or `PHAsset` fetch to get the Live Photo.
- `PHAssetResourceManager.requestData` to pull the paired video resource.
- `AVAssetReader` with `AVAssetReaderTrackOutput` to decode frames in sequence. Do not use `AVAssetImageGenerator` for a full sweep. The reader is faster for reading every frame.
- Output format: `kCVPixelFormatType_32BGRA`.

Tasks:

- Build `ImportService.extractFrames(from:)`. Returns an array of `CVPixelBuffer`.
- Build `FrameStore`. Holds full-res buffers. Builds a downsampled preview copy of each.
- Add a debug action that writes every extracted frame to disk as a PNG.

Done when: you import a Live Photo and see the individual frames written out.

---

## Phase 2: Blend engine (the core)

Goal: average all frames into one long exposure. No selection yet, no UI controls.

This is the technical heart. Get a dumb average working before anything else.

Metal approach:

- Write a compute shader that reduces over N frames.
- Convert each frame from sRGB to linear light before accumulating. Blending in gamma space is wrong and causes artifacts.
- Accumulate in a float texture to avoid clipping.
- Convert back to sRGB on output.

Blend modes (implement average first, then the others):

- Average: sum all frames, divide by count. Motion blur.
- Maximum (lighten): keep the brightest pixel per position. Light trails.
- Minimum (darken): keep the darkest pixel per position. Niche.

Tasks:

- Build `BlendEngine.blend(frames:mode:)`. Returns a `CGImage` or `CVPixelBuffer`.
- Start with average mode only.
- Add a debug action that blends all frames and writes the result to disk.
- Add lighten and darken once average looks correct.

Done when: you produce a real long exposure image from a Live Photo and view it.

---

## Phase 3: Editor UI

Goal: make it interactive. The user picks a frame range and sees the result live.

This is the differentiator. Apple hides frame selection. Spend design energy here.

Tasks:

- Build a timeline strip of frame thumbnails. Use the preview-res frames.
- Add start and end range handles.
- Build the preview canvas that shows the current blend.
- Wire `EditorViewModel` to hold the selected range and blend mode.
- Re-blend on the preview-res frames when handles move. Render full-res only on export.
- Add a blend mode picker: average, lighten, darken.

Performance:

- Blend at preview resolution during interaction.
- Cache partial results. If only the end handle moves, do not re-blend frames that did not change.
- Render full-res once, on export.

Done when: dragging the handles changes the long exposure in real time.

---

## Phase 4: Export

Goal: save the result.

Tasks:

- On export, blend the selected range at full resolution.
- Save to Photos with `PHPhotoLibrary.shared().performChanges`.
- Add a system share sheet.
- Add a resolution choice: standard or full.

Done when: you save a finished long exposure to the photo library.

This is the v1 ship point. Average plus lighten, range selection, live preview, save. Everything after is quality refinement.

---

## Phase 5: Frame registration

Goal: align handheld shots so the static scene stays sharp.

Key APIs:

- `VNHomographicImageRegistrationRequest`: robust alignment. Handles rotation and tilt.
- `VNTranslationalImageRegistrationRequest`: fallback for low-texture scenes.

Method:

- Pick the middle frame as the reference. Least cumulative drift.
- Find the transform on downsampled frames for speed.
- Apply the transform to the full-res frame with Core Image `transformed(by:)`. Transforms scale cleanly.
- Registration fixes the static background only. Moving subjects stay blurred. That is correct.

Tasks:

- Build `RegistrationService.align(frames:reference:)`. Returns transforms.
- Add a toggle in the editor to turn registration on and off.
- Fall back to translation-only when homography fails (low texture, heavy blur).

Done when: a handheld waterfall shot has a sharp background and smooth water.

---

## Phase 6: Exposure normalization

Goal: remove brightness and color flicker across frames.

Why: the camera re-meters during capture. Frame-to-frame brightness and white balance drift cause banding and pulsing in the blend.

Method:

- Linearize frames before measuring. You already do this in the blend engine.
- Match each frame's mean luminance to the reference frame.
- Match per-channel gray point for white balance.
- Downweight or drop outlier frames with sudden exposure jumps.

Tasks:

- Build `NormalizationService.normalize(frames:reference:)`.
- Add a toggle in the editor.
- Order in the pipeline: register first, then normalize, then blend.

Done when: a panned clip blends without visible brightness pulsing.

---

## Phase 7: In-app capture

Goal: capture new footage with locked exposure and white balance.

Why: locked capture produces consistent frames and skips the normalization problem entirely.

Key APIs:

- `AVCaptureSession` with a video data output.
- `AVCaptureDevice.setExposureModeCustom`: lock shutter and ISO.
- `setWhiteBalanceModeLocked`: pin color temperature.

Tasks:

- Build a capture screen.
- Lock exposure and white balance before recording starts.
- Feed captured frames into the same `FrameStore`. The rest of the pipeline is unchanged.

Done when: you capture in-app and edit the result with no normalization needed.

---

## Phase 8: Polish and ship

Tasks:

- Per-frame toggles for manual frame inclusion.
- Reference frame picker (which frame stays sharp).
- Before and after compare.
- Onboarding screen explaining the concept.
- Settings: default blend mode, default export resolution.
- Permission priming before the cold photo prompt.
- Empty state.

App Store prep:

- Enroll in the Apple Developer Program. $99 per year. This is the only hard cost.
- App icon and screenshots.
- Listing copy and a privacy policy. Required even with no data collection.
- App Privacy label: no data collected. On-device processing is a selling point. State it.
- TestFlight beta.
- Submit for review.

Done when: the app is live on the App Store.

---

## Pipeline order (reference)

Always run stages in this order:

```
Import → Register → Normalize → Select → Blend → Export
```

- Register before normalize. Alignment uses feature matching that brightness shifts disrupt.
- Normalize before blend. Blending bad exposures bakes in artifacts.
- Select before blend. The user picks from cleaned, aligned frames.

## The three hard parts

Budget extra time here:

- The Metal blend engine. Reduction over N frames in linear light with selectable mode.
- Preview performance. Re-blending on every handle drag. Solved with preview-res blending and partial-result caching.
- The selection UX. Not hard to code. Easy to make confusing. Prototype it in isolation.

## Cost summary

- Apple Developer Program: $99 per year. Required to publish.
- Everything else: $0. On-device, no backend, no API costs, no per-user cost.