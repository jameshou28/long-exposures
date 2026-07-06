<div align="center">

<img src="long-exposures/long-exposures/Assets.xcassets/AppIcon.appiconset/icon_1024.png" width="120" style="border-radius:26px" alt="Long Exposures app icon"/>

<h1>Long Exposures</h1>

<p><strong>Turn your Live Photos and videos into real long-exposure photographs.</strong><br/></p>

<p>
  <img src="https://img.shields.io/badge/iOS-17%2B-black?style=flat-square" alt="iOS 17+"/>
  <img src="https://img.shields.io/badge/iPhone-only-black?style=flat-square" alt="iPhone only"/>
  <img src="https://img.shields.io/badge/on--device-no%20upload-black?style=flat-square" alt="On-device"/>
  <img src="https://img.shields.io/badge/Swift-SwiftUI%20%2B%20Metal-black?style=flat-square" alt="Swift"/>
</p>

</div>

---

## What it does

Long Exposures is an iOS app that turns your Live Photos and videos into real long-exposure shots. Pick a frame range. Choose a blend mode. Get motion blur, light trails, or glassy reflections without a tripod.

---

## How it works

<div align="center">
<img src="long-exposures/docs/pipeline.svg" width="860" alt="Image pipeline diagram"/>
</div>

<br/>

| Step | What happens |
|---|---|
| **Import** | Your Live Photo's paired video (or any video clip) is decoded frame by frame — up to 120 frames, evenly sampled. Temp files are deleted the moment decoding finishes. |
| **Select** | A scrollable thumbnail strip lets you drag two handles to pick exactly which frames enter the blend. |
| **Align** | Vision estimates a per-frame translation and snaps the static background sharp, so handheld shake doesn't smear the scene you care about. |
| **Match exposure** | Per-channel brightness gains correct the camera's auto-metering flicker between frames, so the blend comes out clean rather than banded. |
| **Smooth motion** | Optical flow synthesizes in-between samples on the GPU, so fast subjects blur into a continuous streak instead of the discrete ghost that comes from low fps. |
| **Blend** | A Metal GPU pipeline accumulates your frames in linear light and resolves them to sRGB. Three modes: Average for motion blur, Lighten for light trails, Darken for reflections and shadows. |
| **Export** | Full-resolution render -> JPEG, saved to the in-app library or straight to Photos. Or export a build-up video — a time-lapse `.mov` of the exposure accumulating frame by frame. |

---

## Features

- **Live Photo & video import** — any clip in your library works
- **In-app capture** with locked exposure and white balance for consistent frames
- **Interactive timeline** — see every frame, drag to choose your range
- **Three blend modes** — Average - Lighten - Darken
- **Frame alignment** — keeps the background sharp on handheld shots
- **Exposure matching** — kills brightness flicker between frames
- **Motion smoothing** — optical-flow in-betweens turn ghosted streaks continuous
- **Before/After** — hold the preview to compare against the original frame
- **Build-up video** — export a time-lapse of the exposure accumulating frame by frame, made to share
- **In-app library** — browse, share, or save past exposures
- **No account. No upload. No network.** All processing happens on your device.

---

## Tech stack

| Layer | Technology |
|---|---|
| UI | SwiftUI |
| GPU blend | Metal compute shaders |
| Frame decode | AVFoundation (`AVAssetReader`) |
| Video export | AVFoundation (`AVAssetWriter`, H.264) |
| Registration | Vision (`VNTranslationalImageRegistrationRequest`) |
| Motion smoothing | Vision (`VNGenerateOpticalFlowRequest`) + Metal warp kernel |
| Color ops | Core Image |
| Photo access | PhotoKit |
| Capture | AVCaptureSession |

No third-party packages. iOS 17+, iPhone only.

---

## Repository layout

```
long-exposures/ 
  Engine/
    BlendEngine.swift     
    BlendKernels.metal    
  Services/
    ImportService.swift   
    RegistrationService.swift
    NormalizationService.swift
    OpticalFlowService.swift  
    ExportService.swift   
    VideoExportService.swift
    CaptureService.swift
    LibraryStore.swift   
  Models/
    FrameStore.swift      
    EditorViewModel.swift 
    Exposure.swift        
    AppSettings.swift     
  Views/
    EditorView.swift      
    TimelineStrip.swift   
    CaptureView.swift     
    LibraryView.swift   
    OnboardingView.swift
    PermissionPriming.swift
landing/                  
```