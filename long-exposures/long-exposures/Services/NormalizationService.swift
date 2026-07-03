//
//  NormalizationService.swift
//  long-exposures
//
//  Removes brightness and white-balance flicker across frames.
//

import Foundation
import CoreImage
import CoreVideo
import simd

/// per-channel linear-light gain applied to a frame to match the reference.
nonisolated struct FrameGain: Sendable {
    let rgb: SIMD3<Float>
    static let unit = FrameGain(rgb: SIMD3<Float>(1, 1, 1))
    var isUnit: Bool { rgb == SIMD3<Float>(1, 1, 1) }
}

nonisolated struct NormalizationService: Sendable {
    /// gains larger/smaller than this are clamped
    private static let gainRange: ClosedRange<Float> = 0.5...2.0

    private static let minMean: Float = 0.004
    func gains(for frames: [CVPixelBuffer], reference referenceIndex: Int,
               using context: CIContext) -> [FrameGain] {
        guard frames.count > 1 else { return frames.map { _ in .unit } }
        let refIndex = min(max(0, referenceIndex), frames.count - 1)

        let means = frames.map { meanLinearRGB(of: $0, using: context) }
        let refMean = means[refIndex]

        return means.enumerated().map { index, mean in
            guard index != refIndex else { return .unit }
            return gain(from: mean, to: refMean)
        }
    }

    private func gain(from mean: SIMD3<Float>, to reference: SIMD3<Float>) -> FrameGain {
        let minMean = Self.minMean
        func channelGain(_ m: Float, _ r: Float) -> Float {
            guard m > minMean else { return 1 }
            return min(max(r / m, Self.gainRange.lowerBound), Self.gainRange.upperBound)
        }
        return FrameGain(rgb: SIMD3<Float>(
            channelGain(mean.x, reference.x),
            channelGain(mean.y, reference.y),
            channelGain(mean.z, reference.z)
        ))
    }

    /// mean rgb of frame in linear light
    private func meanLinearRGB(of buffer: CVPixelBuffer, using context: CIContext) -> SIMD3<Float> {
        let image = CIImage(cvPixelBuffer: buffer)
            .applyingFilter("CISRGBToneCurveToLinear")
        let extent = image.extent
        guard !extent.isInfinite, extent.width > 0, extent.height > 0 else {
            return SIMD3<Float>(repeating: 0)
        }

        let averaged = image.applyingFilter("CIAreaAverage", parameters: [
            kCIInputExtentKey: CIVector(cgRect: extent)
        ])

        var pixel = [Float](repeating: 0, count: 4)
        context.render(averaged,
                       toBitmap: &pixel,
                       rowBytes: 16,
                       bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                       format: .RGBAf,
                       colorSpace: nil)
        return SIMD3<Float>(pixel[0], pixel[1], pixel[2])
    }

    /// applies a linear-light gain to a frame, returning a same-size BGRA buffer
    func apply(_ gain: FrameGain, to buffer: CVPixelBuffer, using context: CIContext) -> CVPixelBuffer {
        guard !gain.isUnit else { return buffer }

        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let source = CIImage(cvPixelBuffer: buffer)

        let normalized = source
            .applyingFilter("CISRGBToneCurveToLinear")
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: CGFloat(gain.rgb.x), y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: CGFloat(gain.rgb.y), z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: CGFloat(gain.rgb.z), w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)
            ])
            .applyingFilter("CILinearToSRGBToneCurve")
            .cropped(to: source.extent)

        guard let output = makeBuffer(width: width, height: height) else { return buffer }
        context.render(normalized, to: output, bounds: source.extent, colorSpace: CGColorSpaceCreateDeviceRGB())
        return output
    }

    func normalize(_ frames: [CVPixelBuffer], reference referenceIndex: Int,
                   using context: CIContext) async -> [CVPixelBuffer] {
        let box = PixelBufferBox(buffers: frames)
        return await Task.detached(priority: .userInitiated) {
            let buffers = box.buffers
            let gains = self.gains(for: buffers, reference: referenceIndex, using: context)
            return PixelBufferBox(buffers: zip(buffers, gains).map { frame, gain in
                self.apply(gain, to: frame, using: context)
            })
        }.value.buffers
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
