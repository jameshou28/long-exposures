//
//  FrameStore.swift
//  long-exposures
//
//  Phase 1: holds full-res CVPixelBuffers plus a downsampled preview-res copy of each.
//  Preview frames drive interactive blending; full-res frames are used on export.
//
//  Phase 5 (registration): alignment is computed per *selection*, not per clip.
//  The reference frame is the centre of the current selection, so the part of the
//  scene the user is actually blending stays sharp. Transforms are cached per
//  reference index, so dragging the far handle (which leaves the centre put)
//  doesn't recompute Vision.
//

import Foundation
import CoreVideo
import CoreImage
import Observation
import UIKit

@Observable
@MainActor
final class FrameStore {

    /// Raw imported frames, untouched. These are the source of truth.
    private(set) var fullResolutionFrames: [CVPixelBuffer] = []
    private(set) var previewFrames: [CVPixelBuffer] = []

    /// When true, the blend pulls registration-aligned frames for the selection.
    private(set) var isRegistered = false

    /// Target long edge for preview-resolution frames, in pixels.
    static let previewLongEdge: CGFloat = 720

    @ObservationIgnored private let ciContext = CIContext()
    @ObservationIgnored private let registration = RegistrationService()

    /// Cache of per-frame transforms keyed by the reference frame they align to.
    /// One entry holds the transform for every frame relative to that reference,
    /// so revisiting a reference (e.g. the far handle moves but the centre doesn't)
    /// reuses the Vision result.
    @ObservationIgnored private var transformCache: [Int: [FrameTransform]] = [:]

    func ingest(frames: [CVPixelBuffer]) {
        fullResolutionFrames = frames
        previewFrames = frames.map { downsample($0) }
        transformCache.removeAll()
        isRegistered = false
    }

    func clear() {
        fullResolutionFrames = []
        previewFrames = []
        transformCache.removeAll()
        isRegistered = false
    }

    func setRegistration(enabled: Bool) {
        isRegistered = enabled
    }

    // MARK: - Aligned frames for a selection

    /// Returns the preview-res frames for `range`, aligned to the centre of `range`
    /// when registration is on. Untouched slice otherwise.
    func previewFrames(for range: ClosedRange<Int>) async -> [CVPixelBuffer] {
        await frames(previewFrames, for: range)
    }

    /// Returns the full-res frames for `range`, aligned to the centre of `range`
    /// when registration is on. Used on export.
    func fullResolutionFrames(for range: ClosedRange<Int>) async -> [CVPixelBuffer] {
        await frames(fullResolutionFrames, for: range)
    }

    private func frames(_ source: [CVPixelBuffer], for range: ClosedRange<Int>) async -> [CVPixelBuffer] {
        let lower = max(0, range.lowerBound)
        let upper = min(source.count - 1, range.upperBound)
        guard lower <= upper else { return [] }
        let slice = Array(source[lower...upper])
        guard isRegistered, slice.count > 1 else { return slice }

        // Reference = centre of the selection, expressed as an absolute frame index.
        let reference = lower + RegistrationService.referenceIndex(frameCount: slice.count)
        let transforms = await transforms(reference: reference)
        return await registration.alignedSlice(of: source, range: lower...upper,
                                               transforms: transforms, context: ciContext)
    }

    /// Per-frame transforms aligning every frame to `reference`, cached.
    /// Estimated on the preview frames (fast); the normalized transforms apply
    /// at full resolution too.
    private func transforms(reference: Int) async -> [FrameTransform] {
        if let cached = transformCache[reference] { return cached }
        let computed = await registration.transformsOffActor(for: previewFrames, reference: reference)
        transformCache[reference] = computed
        return computed
    }

    /// Small UIImages of each preview frame for the timeline strip.
    /// Thumbnails always show the raw frames — the strip is a scrubber, not a
    /// preview of the aligned blend.
    func makeThumbnails(longEdge: CGFloat = 96) -> [UIImage] {
        previewFrames.map { buffer in
            let width = CVPixelBufferGetWidth(buffer)
            let height = CVPixelBufferGetHeight(buffer)
            let scale = min(1.0, longEdge / CGFloat(max(width, height)))
            let ci = CIImage(cvPixelBuffer: buffer)
                .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            guard let cg = ciContext.createCGImage(ci, from: ci.extent) else {
                return UIImage()
            }
            return UIImage(cgImage: cg)
        }
    }

    private func downsample(_ buffer: CVPixelBuffer) -> CVPixelBuffer {
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let longEdge = max(width, height)
        let scale = min(1.0, Self.previewLongEdge / CGFloat(longEdge))
        let targetWidth = max(1, Int(CGFloat(width) * scale))
        let targetHeight = max(1, Int(CGFloat(height) * scale))

        var output: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
        ]
        CVPixelBufferCreate(kCFAllocatorDefault, targetWidth, targetHeight,
                            kCVPixelFormatType_32BGRA, attrs as CFDictionary, &output)
        guard let target = output else { return buffer }

        let ci = CIImage(cvPixelBuffer: buffer).transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        ciContext.render(ci, to: target)
        return target
    }
}
