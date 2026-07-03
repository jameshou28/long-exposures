//
//  FrameStore.swift
//  long-exposures
// 
// store frames
//

import Foundation
import CoreVideo
import CoreImage
import Observation
import UIKit

@Observable
@MainActor
final class FrameStore {

    /// raw imported frames
    private(set) var fullResolutionFrames: [CVPixelBuffer] = []
    private(set) var previewFrames: [CVPixelBuffer] = []

    private(set) var isRegistered = false
    private(set) var isNormalized = false
    private(set) var isInterpolated = false

    static let previewLongEdge: CGFloat = 720

    @ObservationIgnored private let ciContext = CIContext()
    @ObservationIgnored private let registration = RegistrationService()
    @ObservationIgnored private let normalization = NormalizationService()
    @ObservationIgnored private let opticalFlow = OpticalFlowService()
    @ObservationIgnored private var flowCache: [FlowField?]?
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

    /// returns the preview-res frames for range
    func previewFrames(for range: ClosedRange<Int>) async -> [CVPixelBuffer] {
        await frames(previewFrames, for: range)
    }

    /// Returns the full-res frames for range (for export)
    func fullResolutionFrames(for range: ClosedRange<Int>) async -> [CVPixelBuffer] {
        await frames(fullResolutionFrames, for: range)
    }

    private func frames(_ source: [CVPixelBuffer], for range: ClosedRange<Int>) async -> [CVPixelBuffer] {
        let lower = max(0, range.lowerBound)
        let upper = min(source.count - 1, range.upperBound)
        guard lower <= upper else { return [] }
        var slice = Array(source[lower...upper])
        guard slice.count > 1, (isRegistered || isNormalized) else { return slice }

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

    /// smooth motion
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

    private func flowFields() async -> [FlowField?] {
        if let flowCache { return flowCache }
        let computed = await opticalFlow.flowsOffActor(for: previewFrames, using: ciContext)
        flowCache = computed
        return computed
    }



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

    private func transforms(reference: Int) async -> [FrameTransform] {
        if let cached = transformCache[reference] { return cached }
        let computed = await registration.transformsOffActor(for: previewFrames, reference: reference)
        transformCache[reference] = computed
        return computed
    }

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
