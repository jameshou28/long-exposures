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

    private var blendTask: Task<Void, Never>?

    init(frameStore: FrameStore, engine: BlendEngine) {
        self.frameStore = frameStore
        self.engine = engine
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
        let frames = frameStore.previewFrames
        guard !frames.isEmpty else { return }
        isBlending = true
        defer { isBlending = false }
        do {
            let cgImage = try engine.blend(frames: frames, range: start...end, mode: mode)
            guard !Task.isCancelled else { return }
            previewImage = UIImage(cgImage: cgImage)
        } catch {
            print("[long-exposures] preview blend failed: \(error)")
        }
    }
}
