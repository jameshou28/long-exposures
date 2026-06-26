//
//  RegistrationService.swift
//  long-exposures
//
//  Aligns handheld frames so the static background stays sharp while
//  moving subjects (water, clouds, traffic) keep their blur. Vision computes a
//  per-frame translation to the reference frame; we apply it with Core Image.
//
//  Method (translation-only for v1):
//    - Reference = centre of the current selection (set by the caller).
//    - Estimate the translation on the *preview-res* frames for speed.
//    - Apply the same pixel translation to the *full-res* frame (Vision's
//      alignment is in pixels at the analysed resolution; we scale it to the
//      target buffer's size before applying).
//    - Clamp + crop to the original extent so the output buffer is full-size
//      with no tiling or wrap-around.
//
//  Translation corrects small handheld shake (the common case). Rotation and
//  tilt are not corrected in v1. Registration only fixes the static scene; a
//  moving subject staying blurred is the intended long-exposure look.
//

import Foundation
import Vision
import CoreImage
import CoreVideo

/// One frame's alignment to the reference. `.identity` means the frame is the
/// reference or couldn't be aligned (used verbatim). `.translation` carries a
/// pixel offset measured at the resolution the estimate was computed on.
enum FrameTransform: Sendable {
    case identity
    /// Pixel offset and the image width it was measured against, so it can be
    /// rescaled when applied to a different-resolution buffer.
    case translation(dx: CGFloat, dy: CGFloat, measuredWidth: CGFloat)
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

    /// Computes a transform aligning each frame to `reference`. The array is
    /// 1:1 with `frames`; the reference frame's entry is `.identity`.
    ///
    /// `frames` should be the low-res preview buffers — alignment is estimated
    /// there for speed and rescaled when applied at full resolution.
    func transforms(for frames: [CVPixelBuffer], reference referenceIndex: Int) -> [FrameTransform] {
        guard frames.count > 1 else { return frames.map { _ in .identity } }
        let refIndex = min(max(0, referenceIndex), frames.count - 1)
        let reference = frames[refIndex]

        return frames.enumerated().map { index, frame in
            guard index != refIndex else { return .identity }
            return transform(aligning: frame, to: reference)
        }
    }

    /// Aligns `moving` to `reference` with a translation estimate. Identity on failure.
    private func transform(aligning moving: CVPixelBuffer, to reference: CVPixelBuffer) -> FrameTransform {
        let handler = VNSequenceRequestHandler()
        let request = VNTranslationalImageRegistrationRequest(targetedCVPixelBuffer: moving)
        guard (try? handler.perform([request], on: reference)) != nil,
              let observation = request.results?.first as? VNImageTranslationAlignmentObservation
        else { return .identity }

        let t = observation.alignmentTransform
        guard t.tx.isFinite, t.ty.isFinite else { return .identity }

        let width = CGFloat(CVPixelBufferGetWidth(moving))
        return .translation(dx: t.tx, dy: t.ty, measuredWidth: width)
    }

    /// Applies a frame's transform to a buffer, returning an aligned BGRA buffer of
    /// the same dimensions. Edge pixels are clamped (not tiled) where the frame
    /// shifted in from outside, then cropped back to the original extent.
    func apply(_ transform: FrameTransform, to buffer: CVPixelBuffer, using context: CIContext) -> CVPixelBuffer {
        guard case let .translation(dx, dy, measuredWidth) = transform else { return buffer }

        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        // Rescale the pixel offset from the resolution it was measured at to this buffer.
        let scale = measuredWidth > 0 ? CGFloat(width) / measuredWidth : 1
        let offset = CGAffineTransform(translationX: dx * scale, y: dy * scale)

        let source = CIImage(cvPixelBuffer: buffer)
        // Clamp so the shift reveals edge-extended pixels rather than transparency/tiling,
        // then crop back to the original frame rect for a same-size output.
        let aligned = source
            .transformed(by: offset)
            .clampedToExtent()
            .cropped(to: source.extent)

        guard let output = makeBuffer(width: width, height: height) else { return buffer }
        context.render(aligned, to: output, bounds: source.extent, colorSpace: CGColorSpaceCreateDeviceRGB())
        return output
    }

    // MARK: - Off-actor helpers

    /// Aligns each frame in `source[range]` to the precomputed `transforms`,
    /// running the Core Image work off the calling actor.
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
