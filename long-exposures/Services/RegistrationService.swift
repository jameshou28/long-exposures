//
//  RegistrationService.swift
//  long-exposures
//
//  Phase 5: aligns handheld frames so the static background stays sharp while
//  moving subjects (water, clouds, traffic) keep their blur. Vision computes a
//  per-frame transform to the reference frame; we apply it with Core Image.
//
//  Method:
//    - Reference = middle frame (least cumulative drift across the clip).
//    - Estimate each transform on the *preview-res* frames for speed.
//    - Apply the transform to the *full-res* frame. Vision works in a normalized
//      [0,1] space, so the same transform applies at any resolution.
//    - Homography first (handles rotation/tilt); fall back to translation-only
//      when homography fails on low-texture or heavily blurred frames.
//
//  Registration only corrects the static scene. That a moving subject stays
//  blurred is the intended long-exposure look, not a defect.
//

import Foundation
import Vision
import CoreImage
import CoreVideo

/// One frame's alignment to the reference, in Vision's normalized [0,1] space.
/// `.identity` means the frame is the reference or could not be aligned (used verbatim).
enum FrameTransform: Sendable {
    case identity
    case homography(matrix_float3x3)
    case translation(CGAffineTransform)
}

/// CoreVideo's `CVBuffer` isn't `Sendable`, so an array of pixel buffers can't
/// cross a task boundary without a warning. The blend pipeline hands each buffer
/// off and never mutates it concurrently, so moving it is safe — this box asserts
/// that so the off-actor alignment work compiles cleanly under strict concurrency.
nonisolated struct PixelBufferBox: @unchecked Sendable {
    let buffers: [CVPixelBuffer]
}

nonisolated struct RegistrationService: Sendable {

    /// Index of the frame all others are aligned to. Middle frame by default.
    static func referenceIndex(frameCount: Int) -> Int {
        max(0, frameCount / 2)
    }

    /// Computes a transform aligning each frame to `reference`. The arrays are
    /// 1:1 with `frames`; the reference frame's entry is `.identity`.
    ///
    /// `frames` should be the low-res preview buffers — registration is estimated
    /// there for speed and the result reused at full resolution.
    func transforms(for frames: [CVPixelBuffer], reference referenceIndex: Int) -> [FrameTransform] {
        guard frames.count > 1 else { return frames.map { _ in .identity } }
        let refIndex = min(max(0, referenceIndex), frames.count - 1)
        let reference = frames[refIndex]

        return frames.enumerated().map { index, frame in
            guard index != refIndex else { return .identity }
            return transform(aligning: frame, to: reference)
        }
    }

    /// Aligns each frame in `source[range]` to the centre of that range and returns
    /// the aligned buffers. Pass precomputed `transforms` (1:1 with `source`).
    /// Runs the Core Image warps off the calling actor.
    func alignedSlice(of source: [CVPixelBuffer], range: ClosedRange<Int>,
                      transforms: [FrameTransform], context: CIContext) async -> [CVPixelBuffer] {
        let box = PixelBufferBox(buffers: source)
        return await Task.detached(priority: .userInitiated) {
            PixelBufferBox(buffers: range.map { i in
                self.apply(transforms[i], to: box.buffers[i], using: context)
            })
        }.value.buffers
    }

    /// Estimates per-frame transforms aligning every frame to `reference`,
    /// off the calling actor.
    func transformsOffActor(for frames: [CVPixelBuffer], reference: Int) async -> [FrameTransform] {
        let box = PixelBufferBox(buffers: frames)
        return await Task.detached(priority: .userInitiated) {
            self.transforms(for: box.buffers, reference: reference)
        }.value
    }

    /// Aligns `moving` to `reference`. Tries homography, then translation, then identity.
    private func transform(aligning moving: CVPixelBuffer, to reference: CVPixelBuffer) -> FrameTransform {
        let handler = VNSequenceRequestHandler()

        let homography = VNHomographicImageRegistrationRequest(targetedCVPixelBuffer: moving)
        if (try? handler.perform([homography], on: reference)) != nil,
           let observation = homography.results?.first as? VNImageHomographicAlignmentObservation {
            let m = observation.warpTransform
            if isFinite(m) {
                return .homography(m)
            }
        }

        let translation = VNTranslationalImageRegistrationRequest(targetedCVPixelBuffer: moving)
        if (try? handler.perform([translation], on: reference)) != nil,
           let observation = translation.results?.first as? VNImageTranslationAlignmentObservation {
            let t = observation.alignmentTransform
            if t.tx.isFinite && t.ty.isFinite {
                return .translation(t)
            }
        }

        return .identity
    }

    /// Applies a frame's transform to a full-res buffer, returning an aligned BGRA
    /// buffer of the same dimensions. Out-of-bounds areas are left transparent/black,
    /// which is correct: those pixels weren't seen by that frame.
    func apply(_ transform: FrameTransform, to buffer: CVPixelBuffer, using context: CIContext) -> CVPixelBuffer {
        guard transform.isMeaningful else { return buffer }

        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let source = CIImage(cvPixelBuffer: buffer)

        let aligned: CIImage
        switch transform {
        case .identity:
            return buffer
        case .translation(let t):
            // Vision's translation is in pixels relative to image size; CIImage and
            // CVPixelBuffer share a coordinate convention here, so apply directly.
            aligned = source.transformed(by: t)
        case .homography(let m):
            aligned = source.applyingFilter("CIPerspectiveTransformWithExtent", parameters: perspectiveParameters(
                for: m, width: width, height: height, extent: source.extent))
        }

        guard let output = makeBuffer(width: width, height: height) else { return buffer }
        // Clamp the render rect to the original extent so we get a same-size buffer.
        context.render(aligned, to: output, bounds: source.extent, colorSpace: CGColorSpaceCreateDeviceRGB())
        return output
    }

    // MARK: - Homography → CIPerspectiveTransform corners

    /// Vision's warp transform maps reference → moving in normalized [0,1] coords.
    /// CIPerspectiveTransform takes the four destination corners (in image pixels)
    /// the source corners should map to. We map each corner of the image through the
    /// homography to get those destinations.
    private func perspectiveParameters(for m: matrix_float3x3, width: Int, height: Int,
                                       extent: CGRect) -> [String: Any] {
        let w = CGFloat(width)
        let h = CGFloat(height)
        let corners = [
            CGPoint(x: 0, y: 0),   // bottom-left
            CGPoint(x: w, y: 0),   // bottom-right
            CGPoint(x: w, y: h),   // top-right
            CGPoint(x: 0, y: h)    // top-left
        ]
        let mapped = corners.map { warp($0, by: m, width: w, height: h) }
        return [
            "inputExtent": CIVector(cgRect: extent),
            "inputBottomLeft": CIVector(cgPoint: mapped[0]),
            "inputBottomRight": CIVector(cgPoint: mapped[1]),
            "inputTopRight": CIVector(cgPoint: mapped[2]),
            "inputTopLeft": CIVector(cgPoint: mapped[3])
        ]
    }

    /// Maps a pixel point through Vision's normalized homography back to pixel space.
    private func warp(_ point: CGPoint, by m: matrix_float3x3, width: CGFloat, height: CGFloat) -> CGPoint {
        let nx = Float(point.x / width)
        let ny = Float(point.y / height)
        let v = simd_float3(nx, ny, 1)
        let r = m * v
        let denom = r.z == 0 ? 1 : r.z
        return CGPoint(x: CGFloat(r.x / denom) * width, y: CGFloat(r.y / denom) * height)
    }

    // MARK: - Buffer allocation

    private func makeBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        var output: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
        ]
        CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                            kCVPixelFormatType_32BGRA, attrs as CFDictionary, &output)
        return output
    }
}

private nonisolated func isFinite(_ m: matrix_float3x3) -> Bool {
    for col in 0..<3 {
        for row in 0..<3 where !m[col][row].isFinite {
            return false
        }
    }
    return true
}

private nonisolated extension FrameTransform {
    /// Whether applying this transform would change anything.
    var isMeaningful: Bool {
        switch self {
        case .identity: return false
        default: return true
        }
    }
}
