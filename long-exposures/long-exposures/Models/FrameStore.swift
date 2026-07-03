//
//  FrameStore.swift
//  long-exposures
//
//  Holds full-res CVPixelBuffers plus a downsampled preview-res copy of each.
//  Preview frames drive interactive blending; full-res frames are used on export.
//
//  Alignment is computed per *selection*, not per clip. The reference frame is
//  the centre of the current selection, so the part of the scene the user is
//  actually blending stays sharp. Transforms are cached per reference index, so
//  dragging the far handle (which leaves the centre put) doesn't recompute Vision.
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

    /// When true, frames in the selection are exposure/white-balance matched.
    private(set) var isNormalized = false

    /// When true, blends synthesize intermediate samples along optical flow
    /// ("smooth motion") so low-fps sources streak instead of ghosting.
    private(set) var isInterpolated = false

    /// Target long edge for preview-resolution frames, in pixels.
    static let previewLongEdge: CGFloat = 720

    @ObservationIgnored private let ciContext = CIContext()
    @ObservationIgnored private let registration = RegistrationService()
    @ObservationIgnored private let normalization = NormalizationService()
    @ObservationIgnored private let opticalFlow = OpticalFlowService()

    /// Flow for every consecutive preview-frame pair, computed once per import
    /// and kept for the clip's lifetime (registration/normalization toggles
    /// can't invalidate it — see `flowFields()`).
    @ObservationIgnored private var flowCache: [FlowField?]?

    /// Cache of per-frame transforms keyed by the reference frame they align to.
    /// One entry holds the transform for every frame relative to that reference,
    /// so revisiting a reference (e.g. the far handle moves but the centre doesn't)
    /// reuses the Vision result.
    @ObservationIgnored private var transformCache: [Int: [FrameTransform]] = [:]

    func ingest(frames: [CVPixelBuffer]) {
        fullResolutionFrames = frames
        previewFrames = frames.map { downsample($0) }
        transformCache.removeAll()
        flowCache = nil
        isRegistered = false
        isNormalized = false
        isInterpolated = false
    }

    func clear() {
        fullResolutionFrames = []
        previewFrames = []
        transformCache.removeAll()
        flowCache = nil
        isRegistered = false
        isNormalized = false
        isInterpolated = false
    }

    func setRegistration(enabled: Bool) {
        isRegistered = enabled
    }

    func setNormalization(enabled: Bool) {
        isNormalized = enabled
    }

    func setInterpolation(enabled: Bool) {
        isInterpolated = enabled
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
        var slice = Array(source[lower...upper])
        guard slice.count > 1, (isRegistered || isNormalized) else { return slice }

        // Reference = centre of the selection. Pipeline order: register, then normalize.
        let absoluteReference = lower + RegistrationService.referenceIndex(frameCount: slice.count)
        let sliceReference = RegistrationService.referenceIndex(frameCount: slice.count)

        if isRegistered {
            let transforms = await transforms(reference: absoluteReference)
            slice = await registration.alignedSlice(of: source, range: lower...upper,
                                                    transforms: transforms, context: ciContext)
        }
        if isNormalized {
            slice = await normalization.normalize(slice, reference: sliceReference, using: ciContext)
        }
        return slice
    }

    // MARK: - Interpolation (smooth motion)

    /// Interpolation payload covering *all* frames (flows for every consecutive
    /// pair), or nil when the feature is off or flow failed everywhere. Callers
    /// that blend a slice of the frame array slice this payload to match
    /// (`BlendInterpolation.sliced(to:)`); the engine's cached range variant
    /// slices internally. `range` only picks the registration reference so the
    /// shake deltas match the transforms the aligned frames themselves used.
    func interpolation(for range: ClosedRange<Int>) async -> BlendInterpolation? {
        guard isInterpolated, previewFrames.count > 1 else { return nil }
        let flows = await flowFields()
        guard flows.contains(where: { $0 != nil }) else { return nil }

        var shakeDeltas: [SIMD2<Float>] = []
        if isRegistered {
            let lower = max(0, range.lowerBound)
            let upper = min(previewFrames.count - 1, range.upperBound)
            guard lower <= upper else { return nil }
            let reference = lower + RegistrationService.referenceIndex(frameCount: upper - lower + 1)
            let transforms = await transforms(reference: reference)
            shakeDeltas = Self.shakeDeltas(from: transforms, matching: flows)
        }
        return BlendInterpolation(flows: flows, shakeDeltas: shakeDeltas)
    }

    /// Flow for every consecutive preview-frame pair, computed once per import
    /// and cached. Measured on the *raw* preview frames: registration only
    /// translates frames, and that known translation is subtracted in the warp
    /// kernel (shake delta) instead of rerunning Vision per selection
    /// reference. Normalization is a pure gain and doesn't move pixels, so it
    /// can't invalidate flow either.
    private func flowFields() async -> [FlowField?] {
        if let flowCache { return flowCache }
        let computed = await opticalFlow.flowsOffActor(for: previewFrames, using: ciContext)
        flowCache = computed
        return computed
    }

    /// Per-gap translation delta between consecutive frames' registration
    /// transforms, rescaled to each flow's measured resolution. Static content
    /// aligned by shift t sits at (x_ref - t) in the raw frame, so the shake
    /// component baked into raw flow i -> i+1 is t[i] - t[i+1]; the kernel
    /// subtracts it so flow measured on raw frames applies to aligned ones.
    /// Registration translations are Core Image coordinates (y-up) while flow
    /// buffers are top-left origin (y-down), so the vertical component flips.
    private static func shakeDeltas(from transforms: [FrameTransform],
                                    matching flows: [FlowField?]) -> [SIMD2<Float>] {
        guard transforms.count > 1, transforms.count == flows.count + 1 else { return [] }

        func offset(_ transform: FrameTransform, scaledTo flowWidth: CGFloat) -> SIMD2<Float> {
            guard case let .translation(dx, dy, measuredWidth) = transform,
                  measuredWidth > 0 else { return .zero }
            let scale = flowWidth / measuredWidth
            return SIMD2(Float(dx * scale), Float(-dy * scale))
        }

        return (0..<flows.count).map { i in
            guard let flowWidth = flows[i]?.measuredWidth else { return .zero }
            return offset(transforms[i], scaledTo: flowWidth)
                 - offset(transforms[i + 1], scaledTo: flowWidth)
        }
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
