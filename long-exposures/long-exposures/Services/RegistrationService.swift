//
//  RegistrationService.swift
//  long-exposures
//
//  Aligns handheld frames with core image.
//

import Foundation
import Vision
import CoreImage
import CoreVideo

enum FrameTransform: Sendable {
    case identity
    case translation(dx: CGFloat, dy: CGFloat, measuredWidth: CGFloat)
}

nonisolated struct PixelBufferBox: @unchecked Sendable {
    let buffers: [CVPixelBuffer]
}

nonisolated struct RegistrationService: Sendable {

    /// index of the frame all others are alinged to
    static func referenceIndex(frameCount: Int) -> Int {
        max(0, frameCount / 2)
    }

    /// computes a transform aligning each frame to reference frame
    func transforms(for frames: [CVPixelBuffer], reference referenceIndex: Int) -> [FrameTransform] {
        guard frames.count > 1 else { return frames.map { _ in .identity } }
        let refIndex = min(max(0, referenceIndex), frames.count - 1)
        let reference = frames[refIndex]

        return frames.enumerated().map { index, frame in
            guard index != refIndex else { return .identity }
            return transform(aligning: frame, to: reference)
        }
    }

    /// aligns moving frame to reference frame with a translation estimate
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

    /// applies a frame's transform to a buffer
    func apply(_ transform: FrameTransform, to buffer: CVPixelBuffer, using context: CIContext) -> CVPixelBuffer {
        guard case let .translation(dx, dy, measuredWidth) = transform else { return buffer }

        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let scale = measuredWidth > 0 ? CGFloat(width) / measuredWidth : 1
        let offset = CGAffineTransform(translationX: dx * scale, y: dy * scale)

        let source = CIImage(cvPixelBuffer: buffer)
        let aligned = source
            .transformed(by: offset)
            .clampedToExtent()
            .cropped(to: source.extent)

        guard let output = makeBuffer(width: width, height: height) else { return buffer }
        context.render(aligned, to: output, bounds: source.extent, colorSpace: CGColorSpaceCreateDeviceRGB())
        return output
    }
    func alignedSlice(of source: [CVPixelBuffer], range: ClosedRange<Int>,
                      transforms: [FrameTransform], context: CIContext) async -> [CVPixelBuffer] {
        let box = PixelBufferBox(buffers: source)
        return await Task.detached(priority: .userInitiated) {
            PixelBufferBox(buffers: range.map { i in
                self.apply(transforms[i], to: box.buffers[i], using: context)
            })
        }.value.buffers
    }

    func transformsOffActor(for frames: [CVPixelBuffer], reference: Int) async -> [FrameTransform] {
        let box = PixelBufferBox(buffers: frames)
        return await Task.detached(priority: .userInitiated) {
            self.transforms(for: box.buffers, reference: reference)
        }.value
    }

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
