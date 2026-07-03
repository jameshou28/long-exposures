//
//  OpticalFlowService.swift
//  long-exposures
//
//  Dense optical flow between consecutive frames, used to synthesize
//  intermediate samples during a blend ("smooth motion"). Live Photo video is
//  only ~15–30 fps, so averaging the captured frames leaves fast subjects as
//  discrete ghost copies; warping along per-pair flow fills the temporal gaps
//  so motion blurs into a continuous streak.
//
//  Method:
//    - Flow is measured once per import on the preview frames, downsampled
//      further to `flowLongEdge`. Flow fields are spatially smooth, so they
//      upsample cleanly to preview or full resolution at warp time — the
//      kernel rescales by `measuredWidth`, the same pattern
//      RegistrationService uses for its translations.
//    - Vision convention (verifiable with BlendEngine.renderIntermediate):
//      the request targets the *later* frame and is performed on the earlier
//      one, yielding — on the later frame's grid — per-pixel displacement
//      from the earlier frame to the later one, in pixels at the measured size.
//    - A pair that fails just yields nil: the blend skips synthesis for that
//      gap and keeps its ghosting (mirrors RegistrationService's
//      identity-on-failure philosophy).
//

import Foundation
import Vision
import CoreImage
import CoreVideo

/// Dense optical flow for one consecutive frame pair, measured at a reduced
/// resolution. Vectors are in pixels at `measuredWidth`, so they can be
/// rescaled when warping at preview or full resolution.
nonisolated struct FlowField: @unchecked Sendable {
    /// TwoComponent16Half, IOSurface-backed so CVMetalTextureCache can wrap it
    /// zero-copy as rg16Float.
    let buffer: CVPixelBuffer
    /// Width of `buffer` in pixels — the resolution the flow was measured at.
    let measuredWidth: CGFloat
    /// Largest flow magnitude in the field, in pixels at `measuredWidth`.
    /// Drives the adaptive per-gap sample count in the blend.
    let maxMagnitude: Float
}

nonisolated struct OpticalFlowService: Sendable {

    /// Long edge flow is measured at — half the preview res. Bounds the cache:
    /// 166 pairs of rg16f at this size is ~24 MB worst case, ~6 MB typical.
    static let flowLongEdge: CGFloat = 360

    /// Flow for each consecutive pair of `frames`; count is frames.count - 1,
    /// entry i is the flow frame[i] -> frame[i+1]. nil where Vision failed.
    func flows(for frames: [CVPixelBuffer], using context: CIContext) -> [FlowField?] {
        guard frames.count > 1 else { return [] }
        // Downsample each frame once, not once per pair.
        let small = frames.map { downsample($0, using: context) }
        return (0..<(frames.count - 1)).map { flow(from: small[$0], to: small[$0 + 1]) }
    }

    /// Computes `flows(for:using:)` off the calling actor.
    func flowsOffActor(for frames: [CVPixelBuffer], using context: CIContext) async -> [FlowField?] {
        let box = PixelBufferBox(buffers: frames)
        return await Task.detached(priority: .userInitiated) {
            self.flows(for: box.buffers, using: context)
        }.value
    }

    // MARK: - Vision

    /// Flow from `earlier` to `later`, on `later`'s grid. nil on any failure.
    private func flow(from earlier: CVPixelBuffer, to later: CVPixelBuffer) -> FlowField? {
        let request = VNGenerateOpticalFlowRequest(targetedCVPixelBuffer: later)
        request.computationAccuracy = .medium
        request.outputPixelFormat = kCVPixelFormatType_TwoComponent16Half
        let handler = VNImageRequestHandler(cvPixelBuffer: earlier)
        guard (try? handler.perform([request])) != nil,
              let observation = request.results?.first
        else { return nil }
        return copyToMetalCompatibleBuffer(observation.pixelBuffer)
    }

    // MARK: - Buffer copy

    /// Vision's output buffer isn't guaranteed IOSurface-backed, which
    /// CVMetalTextureCacheCreateTextureFromImage requires; copy row-by-row into
    /// one that is, scanning for the max flow magnitude along the way.
    private func copyToMetalCompatibleBuffer(_ source: CVPixelBuffer) -> FlowField? {
        let width = CVPixelBufferGetWidth(source)
        let height = CVPixelBufferGetHeight(source)
        guard width > 0, height > 0,
              CVPixelBufferGetPixelFormatType(source) == kCVPixelFormatType_TwoComponent16Half
        else { return nil }

        var out: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: Int(kCVPixelFormatType_TwoComponent16Half),
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
        ]
        CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                            kCVPixelFormatType_TwoComponent16Half, attrs as CFDictionary, &out)
        guard let destination = out else { return nil }

        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(destination, [])
        defer {
            CVPixelBufferUnlockBaseAddress(destination, [])
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
        }
        guard let sourceBase = CVPixelBufferGetBaseAddress(source),
              let destinationBase = CVPixelBufferGetBaseAddress(destination) else { return nil }

        let sourceRowBytes = CVPixelBufferGetBytesPerRow(source)
        let destinationRowBytes = CVPixelBufferGetBytesPerRow(destination)
        let contentBytes = width * 2 * MemoryLayout<UInt16>.size

        var maxSquared: Float = 0
        for row in 0..<height {
            let sourceRow = sourceBase.advanced(by: row * sourceRowBytes)
            memcpy(destinationBase.advanced(by: row * destinationRowBytes), sourceRow, contentBytes)

            // Strided scan (every 4th pixel) is plenty for a maximum that only
            // picks a per-gap sample count.
            let halves = sourceRow.bindMemory(to: UInt16.self, capacity: width * 2)
            var x = 0
            while x < width {
                let dx = Self.float(fromHalf: halves[x * 2])
                let dy = Self.float(fromHalf: halves[x * 2 + 1])
                let squared = dx * dx + dy * dy
                if squared.isFinite, squared > maxSquared { maxSquared = squared }
                x += 4
            }
        }

        return FlowField(buffer: destination,
                         measuredWidth: CGFloat(width),
                         maxMagnitude: maxSquared.squareRoot())
    }

    /// IEEE 754 half -> Float without Float16 (unavailable on Intel simulators).
    private static func float(fromHalf bits: UInt16) -> Float {
        let sign: Float = (bits & 0x8000) != 0 ? -1 : 1
        let exponent = Int((bits >> 10) & 0x1F)
        let mantissa = Float(bits & 0x3FF)
        switch exponent {
        case 0:     return sign * mantissa * powf(2, -24)          // subnormal
        case 0x1F:  return mantissa == 0 ? sign * .infinity : .nan
        default:    return sign * (1 + mantissa / 1024) * powf(2, Float(exponent - 15))
        }
    }

    // MARK: - Downsample

    /// Scales a preview frame down to `flowLongEdge` for flow estimation.
    /// Same approach as FrameStore.downsample; kept local so the service is
    /// self-contained off-actor.
    private func downsample(_ buffer: CVPixelBuffer, using context: CIContext) -> CVPixelBuffer {
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let scale = min(1.0, Self.flowLongEdge / CGFloat(max(width, height)))
        guard scale < 1.0 else { return buffer }
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
        context.render(ci, to: target)
        return target
    }
}
