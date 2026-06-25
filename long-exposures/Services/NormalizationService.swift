//
//  NormalizationService.swift
//  long-exposures
//
//  Phase 6: removes brightness and white-balance flicker across frames. The
//  camera re-meters during capture, so frame-to-frame luminance and colour drift
//  cause banding and pulsing in the blend. We match every frame to the reference.
//
//  Method (per the plan):
//    - Linearize before measuring — gamma-space means are wrong.
//    - Measure each frame's mean linear RGB and the reference's.
//    - Per-channel gain = referenceMean / frameMean. Matching all three channels
//      corrects luminance (overall) and white balance (per-channel) in one step.
//    - Clamp gains so an outlier frame (a sudden exposure jump, a near-black or
//      blown frame) can't apply an extreme multiplier and bake in artifacts.
//    - Apply the gain in linear light, then return to sRGB.
//
//  Pipeline order: register first, then normalize, then blend.
//

import Foundation
import CoreImage
import CoreVideo
import simd

/// Per-channel linear-light gain applied to a frame to match the reference.
/// `.unit` (1,1,1) leaves a frame unchanged (the reference, or a failed measure).
nonisolated struct FrameGain: Sendable {
    let rgb: SIMD3<Float>
    static let unit = FrameGain(rgb: SIMD3<Float>(1, 1, 1))

    var isUnit: Bool { rgb == SIMD3<Float>(1, 1, 1) }
}

nonisolated struct NormalizationService: Sendable {

    /// Gains larger/smaller than this are clamped — a frame needing a 3× boost is
    /// an outlier (exposure jump) we don't want to amplify into the blend.
    private static let gainRange: ClosedRange<Float> = 0.5...2.0

    /// A measured mean at or below this (linear) is treated as too dark to trust;
    /// the frame gets unit gain rather than a divide-by-near-zero blow-up.
    private static let minMean: Float = 0.004

    /// Per-frame gains aligning each frame's mean linear RGB to `referenceIndex`.
    /// 1:1 with `frames`; the reference entry is `.unit`.
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

    /// Mean RGB of a frame in linear light, in [0,1] per channel.
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

    /// Applies a linear-light gain to a frame, returning a same-size BGRA buffer.
    /// Linearize → multiply → back to sRGB so the scaling matches the measurement.
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

    // MARK: - Off-actor helper

    /// Measures gains then applies them to `frames`, running the Core Image work
    /// off the calling actor. `frames` are the already-sliced (and possibly
    /// already-registered) buffers for the selection.
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
