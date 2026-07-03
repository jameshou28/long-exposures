//
//  EditorViewModel.swift
//  long-exposures
//
//  Drives the interactive editor. Holds the selected frame range and blend mode,
//  regenerates the preview on the preview-res frames when the selection changes,
//  and exposes thumbnails for the timeline strip.
//
//  Interaction blends at preview resolution; the BlendEngine caches per range
//  so dragging back over a visited range is instant. Full-res render happens
//  only on export.
//

import Foundation
import CoreVideo
import Observation
import UIKit

@Observable
@MainActor
final class EditorViewModel {

    private let frameStore: FrameStore
    private let engine: BlendEngine

    var thumbnails: [UIImage] = []
    var previewImage: UIImage?

    /// Continuous blend control: -1 = darken (min), 0 = average, +1 = lighten (max).
    /// Replaces the old discrete average/lighten/darken picker.
    var blendBias: Double = 0 {
        didSet { if blendBias != oldValue { scheduleBlend() } }
    }

    /// Inclusive selected range over preview-frame indices.
    var selectionStart: Int = 0 {
        didSet { if selectionStart != oldValue { scheduleBlend() } }
    }
    var selectionEnd: Int = 0 {
        didSet { if selectionEnd != oldValue { scheduleBlend() } }
    }

    var frameCount: Int { frameStore.previewFrames.count }
    var isBlending = false
    var previewError: String?

    /// Aligns handheld frames so the static background stays sharp.
    /// Alignment is computed around the *centre of the current selection*, so the
    /// part of the scene being blended is what stays sharp.
    var registrationEnabled = false {
        didSet {
            guard registrationEnabled != oldValue else { return }
            frameStore.setRegistration(enabled: registrationEnabled)
            engine.invalidateCache()
            scheduleBlend()
        }
    }
    var isRegistering = false

    /// Matches per-frame brightness and white balance to the selection's centre
    /// frame, removing the pulsing/banding the camera's re-metering causes.
    var normalizationEnabled = false {
        didSet {
            guard normalizationEnabled != oldValue else { return }
            frameStore.setNormalization(enabled: normalizationEnabled)
            engine.invalidateCache()
            scheduleBlend()
        }
    }

    /// Synthesizes intermediate samples along optical flow so fast subjects
    /// blur into a continuous streak instead of discrete ghost copies (Live
    /// Photo video is only ~15–30 fps).
    var interpolationEnabled = false {
        didSet {
            guard interpolationEnabled != oldValue else { return }
            frameStore.setInterpolation(enabled: interpolationEnabled)
            if !interpolationEnabled { flowUnavailable = false }
            engine.invalidateCache()
            scheduleBlend()
        }
    }
    /// True while the per-pair flow fields are being computed — the first
    /// blend after enabling runs N-1 Vision requests; later blends reuse them.
    var isComputingFlow = false
    /// True when smooth motion is on but flow estimation produced nothing —
    /// Vision failed on every frame pair (it can't run in the simulator at
    /// all), so the blend is silently identical to the toggle being off.
    /// Surfaced in the UI so a total failure isn't mistaken for a weak effect.
    var flowUnavailable = false

    /// True while either registration or normalization is reprocessing the selection.
    private var processesFramesPerSelection: Bool { registrationEnabled || normalizationEnabled }

    /// Whether the user is holding the preview to compare against a single sharp
    /// frame (before/after). Doesn't re-blend; toggles which image is shown.
    var isComparing = false {
        didSet { if isComparing != oldValue { Task { await refreshDisplayedImage() } } }
    }
    /// The last blended result, kept so compare can swap back without re-blending.
    private var blendedImage: UIImage?
    /// A sharp single-frame image for compare, at preview res.
    private var compareImage: UIImage?

    // Export state.
    var isExporting = false
    var exportMessage: String?
    var exportResolution: ExportResolution = .full

    private var blendTask: Task<Void, Never>?
    private let library: LibraryStore

    init(frameStore: FrameStore, engine: BlendEngine, library: LibraryStore, settings: AppSettings) {
        self.frameStore = frameStore
        self.engine = engine
        self.library = library
        self.blendBias = Double(settings.defaultMode.bias)
        self.exportResolution = settings.defaultResolution
    }

    /// Reset selection to the full clip and rebuild thumbnails after an import.
    func load() {
        engine.invalidateCache()
        thumbnails = frameStore.makeThumbnails()
        let count = frameStore.previewFrames.count
        selectionStart = 0
        selectionEnd = max(0, count - 1)
        scheduleBlend()
    }

    /// Coalesce rapid selection changes during a drag into a single trailing blend.
    private func scheduleBlend() {
        guard frameStore.previewFrames.count > 0 else { return }
        blendTask?.cancel()
        let start = min(selectionStart, selectionEnd)
        let end = max(selectionStart, selectionEnd)
        let bias = Float(blendBias)

        blendTask = Task { [weak self] in
            // Brief debounce so a fast drag doesn't queue a blend per frame.
            try? await Task.sleep(for: .milliseconds(30))
            guard !Task.isCancelled, let self else { return }
            await self.blend(start: start, end: end, bias: bias)
        }
    }

    private func blend(start: Int, end: Int, bias: Float) async {
        guard frameStore.previewFrames.count > 0 else { return }
        isBlending = true
        if processesFramesPerSelection { isRegistering = true }
        defer {
            isBlending = false
            isRegistering = false
        }

        do {
            // Synthesized in-betweens (smooth motion). The payload covers every
            // frame pair; the engine's range variant slices it, and the aligned
            // path slices it here to match its sliced frame array.
            var interpolation: BlendInterpolation?
            if interpolationEnabled {
                isComputingFlow = true
                interpolation = await frameStore.interpolation(for: start...end)
                isComputingFlow = false
                guard !Task.isCancelled else { return }
                flowUnavailable = interpolation == nil
            }

            let cgImage: CGImage
            // Compare shows the selection's centre frame — the natural sharp reference.
            let compareSliceIndex = RegistrationService.referenceIndex(frameCount: end - start + 1)

            if processesFramesPerSelection {
                let frames = await frameStore.previewFrames(for: start...end)
                guard !Task.isCancelled, !frames.isEmpty else { return }
                cgImage = try engine.blend(frames: frames, bias: bias,
                                           interpolation: interpolation?.sliced(to: start...end))
                let cmp = min(compareSliceIndex, frames.count - 1)
                compareImage = UIImage(cgImage: try engine.render(frame: frames[cmp]))
            } else {
                let frames = frameStore.previewFrames
                guard !frames.isEmpty else { return }
                cgImage = try engine.blend(frames: frames, range: start...end, bias: bias,
                                           interpolation: interpolation)
                let absolute = min(start + compareSliceIndex, frames.count - 1)
                compareImage = UIImage(cgImage: try engine.render(frame: frames[absolute]))
            }
            guard !Task.isCancelled else { return }
            blendedImage = UIImage(cgImage: cgImage)
            previewError = nil
            await refreshDisplayedImage()
        } catch {
            previewError = "Preview failed: \(error.localizedDescription)"
        }
    }

    /// Shows either the blend or, while comparing, a single sharp frame.
    private func refreshDisplayedImage() async {
        if isComparing, let compareImage {
            previewImage = compareImage
        } else {
            previewImage = blendedImage
        }
    }

    /// Renders the current selection at full resolution, saves it to the in-app
    /// library, and optionally to the system Photos library.
    func export(saveToPhotos: Bool) async {
        guard frameStore.fullResolutionFrames.count > 0 else { return }
        let start = min(selectionStart, selectionEnd)
        let end = max(selectionStart, selectionEnd)
        let bias = Float(blendBias)
        let label = BlendMode.label(forBias: bias)
        let frameCount = end - start + 1

        isExporting = true
        exportMessage = "Rendering full resolution…"
        defer { isExporting = false }

        do {
            // Full-res frames, aligned to this selection's centre when registration
            // is on. Already sliced to the range, so blend the whole array.
            let frames = await frameStore.fullResolutionFrames(for: start...end)
            guard !frames.isEmpty else { return }
            // Full res reuses the low-res flow fields — the warp kernel rescales
            // them by measuredWidth, the same way registration rescales its
            // translations. Sliced to match the sliced frame array.
            let interpolation = interpolationEnabled
                ? await frameStore.interpolation(for: start...end)?.sliced(to: start...end)
                : nil
            let service = ExportService(engine: engine)
            let cgImage = try service.renderFullResolution(
                frames: frames, range: 0...(frames.count - 1), bias: bias,
                resolution: exportResolution, interpolation: interpolation)
            try library.add(image: cgImage, modeLabel: label, frameCount: frameCount)
            if saveToPhotos {
                try await ExportService.saveToPhotos(cgImage)
                exportMessage = "Saved to library and Photos."
            } else {
                exportMessage = "Saved to library."
            }
        } catch {
            exportMessage = "Export failed: \(error.localizedDescription)"
        }
    }
}
