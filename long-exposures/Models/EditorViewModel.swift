//
//  EditorViewModel.swift
//  long-exposures
//
//  Phase 3: drives the interactive editor. Holds the selected frame range and
//  blend mode, regenerates the preview on the preview-res frames when the
//  selection changes, and exposes thumbnails for the timeline strip.
//
//  Interaction blends at preview resolution; the BlendEngine caches per range
//  so dragging back over a visited range is instant. Full-res render happens
//  only on export (Phase 4).
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
    var mode: BlendMode = .average {
        didSet { scheduleBlend() }
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

    /// Aligns handheld frames so the static background stays sharp (Phase 5).
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

    // Export state.
    var isExporting = false
    var exportMessage: String?
    var exportResolution: ExportResolution = .full

    private var blendTask: Task<Void, Never>?
    private let library: LibraryStore

    init(frameStore: FrameStore, engine: BlendEngine, library: LibraryStore) {
        self.frameStore = frameStore
        self.engine = engine
        self.library = library
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
        let mode = mode

        blendTask = Task { [weak self] in
            // Brief debounce so a fast drag doesn't queue a blend per frame.
            try? await Task.sleep(for: .milliseconds(30))
            guard !Task.isCancelled, let self else { return }
            await self.blend(start: start, end: end, mode: mode)
        }
    }

    private func blend(start: Int, end: Int, mode: BlendMode) async {
        guard frameStore.previewFrames.count > 0 else { return }
        isBlending = true
        if registrationEnabled { isRegistering = true }
        defer {
            isBlending = false
            isRegistering = false
        }
        do {
            let cgImage: CGImage
            if registrationEnabled {
                // Aligned to the centre of *this* selection. The aligned pixels
                // change with the selection, so bypass the engine's range cache.
                let frames = await frameStore.previewFrames(for: start...end)
                guard !Task.isCancelled, !frames.isEmpty else { return }
                cgImage = try engine.blend(frames: frames, mode: mode)
            } else {
                // Raw frames: the cached range blend makes drag-replay instant.
                let frames = frameStore.previewFrames
                guard !frames.isEmpty else { return }
                cgImage = try engine.blend(frames: frames, range: start...end, mode: mode)
            }
            guard !Task.isCancelled else { return }
            previewImage = UIImage(cgImage: cgImage)
            previewError = nil
        } catch {
            previewError = "Preview failed: \(error.localizedDescription)"
            print("[long-exposures] preview blend failed: \(error)")
        }
    }

    /// Renders the current selection at full resolution, saves it to the in-app
    /// library, and optionally to the system Photos library.
    func export(saveToPhotos: Bool) async {
        guard frameStore.fullResolutionFrames.count > 0 else { return }
        let start = min(selectionStart, selectionEnd)
        let end = max(selectionStart, selectionEnd)
        let mode = mode
        let frameCount = end - start + 1

        isExporting = true
        exportMessage = "Rendering full resolution…"
        defer { isExporting = false }

        do {
            // Full-res frames, aligned to this selection's centre when registration
            // is on. Already sliced to the range, so blend the whole array.
            let frames = await frameStore.fullResolutionFrames(for: start...end)
            guard !frames.isEmpty else { return }
            let service = ExportService(engine: engine)
            let cgImage = try service.renderFullResolution(
                frames: frames, range: 0...(frames.count - 1), mode: mode, resolution: exportResolution)
            try library.add(image: cgImage, mode: mode, frameCount: frameCount)
            if saveToPhotos {
                try await ExportService.saveToPhotos(cgImage)
                exportMessage = "Saved to library and Photos."
            } else {
                exportMessage = "Saved to library."
            }
        } catch {
            exportMessage = "Export failed: \(error.localizedDescription)"
            print("[long-exposures] export failed: \(error)")
        }
    }
}
