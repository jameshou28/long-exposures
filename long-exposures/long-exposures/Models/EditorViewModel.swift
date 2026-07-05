//
//  EditorViewModel.swift
//  long-exposures
//
//  drives the interactive editor
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

    /// blend control: -1 = darken (min), 0 = average, +1 = lighten (max)
    var blendBias: Double = 0 {
        didSet { if blendBias != oldValue { scheduleBlend() } }
    }
    /// frame selection
    var selectionStart: Int = 0 {
        didSet { if selectionStart != oldValue { scheduleBlend() } }
    }
    var selectionEnd: Int = 0 {
        didSet { if selectionEnd != oldValue { scheduleBlend() } }
    }

    var frameCount: Int { frameStore.previewFrames.count }
    var isBlending = false
    var previewError: String?

    /// frame alignment
    var registrationEnabled = false {
        didSet {
            guard registrationEnabled != oldValue else { return }
            frameStore.setRegistration(enabled: registrationEnabled)
            engine.invalidateCache()
            scheduleBlend()
        }
    }
    var isRegistering = false

    /// exposure normalizing
    var normalizationEnabled = false {
        didSet {
            guard normalizationEnabled != oldValue else { return }
            frameStore.setNormalization(enabled: normalizationEnabled)
            engine.invalidateCache()
            scheduleBlend()
        }
    }

    var interpolationEnabled = false {
        didSet {
            guard interpolationEnabled != oldValue else { return }
            frameStore.setInterpolation(enabled: interpolationEnabled)
            if !interpolationEnabled { flowUnavailable = false }
            engine.invalidateCache()
            scheduleBlend()
        }
    }

    var isComputingFlow = false
    var flowUnavailable = false
    private var processesFramesPerSelection: Bool { registrationEnabled || normalizationEnabled }
    var isComparing = false {
        didSet { if isComparing != oldValue { Task { await refreshDisplayedImage() } } }
    }
    /// last blended result
    private var blendedImage: UIImage?
    private var compareImage: UIImage?

    // export state
    var isExporting = false
    var exportMessage: String?
    var exportResolution: ExportResolution = .full

    // build-up video export
    var isExportingVideo = false
    var videoProgress: Double = 0
    var videoURL: URL?

    @ObservationIgnored private let ciContext = CIContext()

    /// build-up video tuning: ~4s body + ~1s tail at 30fps
    private static let videoFPS = 30
    private static let videoLongEdgeCap: CGFloat = 1080

    private var blendTask: Task<Void, Never>?
    private let library: LibraryStore

    init(frameStore: FrameStore, engine: BlendEngine, library: LibraryStore, settings: AppSettings) {
        self.frameStore = frameStore
        self.engine = engine
        self.library = library
        self.blendBias = Double(settings.defaultMode.bias)
        self.exportResolution = settings.defaultResolution
    }

    func load() {
        engine.invalidateCache()
        thumbnails = frameStore.makeThumbnails()
        let count = frameStore.previewFrames.count
        selectionStart = 0
        selectionEnd = max(0, count - 1)
        scheduleBlend()
    }

    private func scheduleBlend() {
        guard frameStore.previewFrames.count > 0 else { return }
        blendTask?.cancel()
        let start = min(selectionStart, selectionEnd)
        let end = max(selectionStart, selectionEnd)
        let bias = Float(blendBias)

        blendTask = Task { [weak self] in
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
            var interpolation: BlendInterpolation?
            if interpolationEnabled {
                isComputingFlow = true
                interpolation = await frameStore.interpolation(for: start...end)
                isComputingFlow = false
                guard !Task.isCancelled else { return }
                flowUnavailable = interpolation == nil
            }

            let cgImage: CGImage
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
    private func refreshDisplayedImage() async {
        if isComparing, let compareImage {
            previewImage = compareImage
        } else {
            previewImage = blendedImage
        }
    }

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
            let frames = await frameStore.fullResolutionFrames(for: start...end)
            guard !frames.isEmpty else { return }
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

    /// Renders build up vid
    func exportVideo() async {
        guard frameStore.fullResolutionFrames.count > 0 else { return }
        let start = min(selectionStart, selectionEnd)
        let end = max(selectionStart, selectionEnd)
        let bias = Float(blendBias)

        guard end - start + 1 >= 2 else {
            exportMessage = "Select at least two frames for a build-up video."
            return
        }

        isExportingVideo = true
        videoProgress = 0
        videoURL = nil
        exportMessage = "Rendering build-up video…"
        defer { isExportingVideo = false }

        do {
            let frames = await frameStore.fullResolutionFrames(for: start...end)
            guard frames.count >= 2 else { return }
            let interpolation = interpolationEnabled
                ? await frameStore.interpolation(for: start...end)?.sliced(to: start...end)
                : nil

            let fps = Self.videoFPS
            let holdFrames = fps
            let maxBodyFrames = fps * 4

            guard let renderer = try BuildUpVideoRenderer(
                engine: engine, frames: frames, interpolation: interpolation, bias: bias,
                longEdgeCap: Self.videoLongEdgeCap, ciContext: ciContext,
                maxBodyFrames: maxBodyFrames)
            else {
                exportMessage = "Not enough frames to build a video."
                return
            }

            let totalFrames = renderer.indices.count + holdFrames
            let service = VideoExportService()
            let url = try await service.encode(
                totalFrames: totalFrames, size: renderer.size, fps: fps,
                frameProvider: { try renderer.composite(at: $0) },
                onProgress: { [weak self] fraction in
                    Task { @MainActor in self?.videoProgress = fraction }
                })

            videoURL = url
            videoProgress = 1
            exportMessage = "Video ready to share."
        } catch {
            exportMessage = "Video export failed: \(error.localizedDescription)"
        }
    }

    func saveVideoToPhotos() async {
        guard let videoURL else { return }
        do {
            try await ExportService.saveVideoToPhotos(videoURL)
            exportMessage = "Video saved to Photos."
        } catch {
            exportMessage = "Couldn't save video: \(error.localizedDescription)"
        }
    }
}
