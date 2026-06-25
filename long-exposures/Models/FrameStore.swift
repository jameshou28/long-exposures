//
//  FrameStore.swift
//  long-exposures
//
//  Phase 1: holds full-res CVPixelBuffers plus a downsampled preview-res copy of each.
//  Preview frames drive interactive blending; full-res frames are used on export.
//

import Foundation
import CoreVideo
import CoreImage
import Observation
import UIKit

@Observable
@MainActor
final class FrameStore {

    private(set) var fullResolutionFrames: [CVPixelBuffer] = []
    private(set) var previewFrames: [CVPixelBuffer] = []

    /// Target long edge for preview-resolution frames, in pixels.
    static let previewLongEdge: CGFloat = 720

    @ObservationIgnored private let ciContext = CIContext()

    func ingest(frames: [CVPixelBuffer]) {
        fullResolutionFrames = frames
        previewFrames = frames.map { downsample($0) }
    }

    func clear() {
        fullResolutionFrames = []
        previewFrames = []
    }

    /// Small UIImages of each preview frame for the timeline strip.
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
