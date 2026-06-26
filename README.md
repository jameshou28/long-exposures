# Long Exposures

An iOS app that turns Live Photos and videos into long-exposure photographs — where **you** pick which frames blend.

Silky water, light trails, motion blur. No tripod. No upload. All on-device.

---

## How it works

![Pipeline diagram](long-exposures/docs/pipeline.svg)

### Pipeline

```
Input → Extract Frames → Store → [Align] → [Match Exposure] → Select Range → Blend → Export
```

| Stage | Service | What happens |
|---|---|---|
| **Input** | `ImportService` | Live Photo paired video or any video file is decoded to BGRA `CVPixelBuffer` frames via `AVAssetReader`. Long clips are sampled evenly down to 120 frames. Temp files are deleted immediately after decode. |
| **Store** | `FrameStore` | Raw full-res buffers + a 720px preview copy of each are kept in memory. The preview set drives interactive blending; full-res is used only on export. |
| **Align** *(optional)* | `RegistrationService` | Vision `VNTranslationalImageRegistrationRequest` estimates a per-frame translation to the selection's centre frame. Computed on preview-res for speed, then rescaled and applied to full-res via Core Image before export. Corrects handheld shake so the background stays sharp while moving subjects blur. |
| **Match exposure** *(optional)* | `NormalizationService` | Measures each frame's mean linear RGB, derives per-channel gain relative to the centre frame (clamped 0.5–2×), and applies it via `CIColorMatrix`. Kills the pulsing/banding the camera's auto-metering causes. |
| **Select range** | `TimelineStrip` | A scrollable thumbnail strip with two draggable handles. You choose exactly which frames enter the blend. |
| **Blend** | `BlendEngine` (Metal) | Frames are accumulated in a `rgba32Float` texture in linear light, then resolved to sRGB. Three modes: **Average** (motion blur), **Lighten** / max (light trails), **Darken** / min. An LRU cache makes revisiting ranges instant during drag. |
| **Export** | `ExportService` | Full-res blend → `CGImage` → JPEG (quality 0.95). Saved to the in-app library and optionally to system Photos. |

---

## Features

- **Import** Live Photos or any video from your library
- **Capture** directly in-app with locked exposure and white balance for consistent frames
- **Interactive timeline** — drag range handles to pick exactly the frames you want
- **Three blend modes**: Average · Lighten · Darken
- **Frame alignment** — Vision-based translation registration for handheld shots
- **Exposure matching** — normalises brightness flicker between frames
- **Before / After** — hold the preview to compare the blend with the original frame
- **In-app library** — browse, share, or save past exposures
- **Fully on-device** — no account, no upload, no network

---

## Tech stack

| Layer | Technology |
|---|---|
| UI | SwiftUI |
| GPU blend | Metal compute shaders |
| Frame decode | AVFoundation (`AVAssetReader`) |
| Registration | Vision (`VNTranslationalImageRegistrationRequest`) |
| Color ops | Core Image |
| Photo access | PhotoKit |
| Capture | AVCaptureSession |

- iOS 17+, iPhone only
- No third-party packages

---

## Repository layout

```
long-exposures/           ← Xcode project
  Engine/
    BlendEngine.swift     ← Metal accumulate + resolve pipeline
    BlendKernels.metal    ← GPU kernels (average / lighten / darken / resolve)
  Services/
    ImportService.swift   ← PHAsset / video → CVPixelBuffer frames
    RegistrationService.swift  ← Vision frame alignment
    NormalizationService.swift ← Per-frame exposure matching
    ExportService.swift   ← Full-res render + save
    CaptureService.swift  ← In-app locked-exposure video capture
    LibraryStore.swift    ← On-device JPEG library + index
  Models/
    FrameStore.swift      ← Full-res + preview buffer store
    EditorViewModel.swift ← Selection state, debounced preview re-blend
    Exposure.swift        ← Codable metadata for saved exposures
    AppSettings.swift     ← UserDefaults-backed defaults
  Views/
    EditorView.swift      ← Preview canvas + controls
    TimelineStrip.swift   ← Draggable range timeline
    CaptureView.swift     ← Live camera preview + record button
    LibraryView.swift     ← Saved exposures grid + detail
    OnboardingView.swift  ← First-launch walkthrough
    PermissionPriming.swift ← Pre-permission explanation sheets
landing/                  ← Marketing site (React + Vite → Vercel)
```

---

## Building

Open `long-exposures/long-exposures.xcodeproj` in Xcode 15+. No package fetch needed — the project uses system frameworks only.

The blend engine and capture path require a real device. The import flow and library work in the simulator.
