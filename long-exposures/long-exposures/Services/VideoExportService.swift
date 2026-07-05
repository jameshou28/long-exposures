//
//  VideoExportService.swift
//  long-exposures
//
//  build up vid export
//

import Foundation
import AVFoundation
import CoreVideo
import CoreGraphics
import CoreImage
import simd

enum VideoExportError: LocalizedError {
    case writerSetupFailed
    case pixelBufferPoolUnavailable
    case pixelBufferCreationFailed
    case appendFailed
    case finalizeFailed(String)

    var errorDescription: String? {
        switch self {
        case .writerSetupFailed: return "Could not set up the video writer."
        case .pixelBufferPoolUnavailable: return "The video writer has no pixel buffer pool."
        case .pixelBufferCreationFailed: return "Could not create a video frame buffer."
        case .appendFailed: return "Failed to append a frame to the video."
        case .finalizeFailed(let m): return "Could not finish writing the video: \(m)."
        }
    }
}

final class BuildUpVideoRenderer: @unchecked Sendable {

    private let engine: BlendEngine
    private let frames: [CVPixelBuffer]
    private let interpolation: BlendInterpolation?
    private let bias: Float
    private let accumulator: BlendAccumulator

    let indices: [Int]
    let size: CGSize

    private var accumulatedUpTo = -1
    private var lastComposite: CGImage?

    init?(engine: BlendEngine, frames: [CVPixelBuffer], interpolation: BlendInterpolation?,
          bias: Float, longEdgeCap: CGFloat, ciContext: CIContext,
          maxBodyFrames: Int) throws {
        guard frames.count >= 2, let first = frames.first else { return nil }

        let size = Self.cappedEvenSize(of: first, longEdgeCap: longEdgeCap)
        let scaled = frames.map { Self.downsample($0, to: size, using: ciContext) }

        let n = scaled.count
        let stride = max(1, Int((Double(n) / Double(maxBodyFrames)).rounded(.up)))
        var indices = Swift.stride(from: stride, to: n, by: stride).map { $0 }
        if indices.last != n - 1 { indices.append(n - 1) } 

        self.engine = engine
        self.frames = scaled
        self.interpolation = interpolation
        self.bias = bias
        self.size = size
        self.indices = indices
        self.accumulator = try engine.makeAccumulator(width: Int(size.width), height: Int(size.height))
    }

    func composite(at videoIndex: Int) throws -> CGImage {
        let target = indices[min(videoIndex, indices.count - 1)]
        if accumulatedUpTo >= target, let lastComposite { return lastComposite }

        while accumulatedUpTo < target {
            let i = accumulatedUpTo + 1
            let next = i + 1 < frames.count ? frames[i + 1] : nil
            let flow = interpolation.flatMap { i < $0.flows.count ? $0.flows[i] : nil }
            let shakeDelta = interpolation.flatMap {
                i < $0.shakeDeltas.count ? $0.shakeDeltas[i] : nil
            } ?? .zero
            try engine.accumulate(frames[i], next: next, flow: flow,
                                  shakeDelta: shakeDelta, into: accumulator)
            accumulatedUpTo = i
        }

        let image = try engine.resolve(accumulator, bias: bias)
        lastComposite = image
        return image
    }

    private static func cappedEvenSize(of buffer: CVPixelBuffer, longEdgeCap: CGFloat) -> CGSize {
        let width = CGFloat(CVPixelBufferGetWidth(buffer))
        let height = CGFloat(CVPixelBufferGetHeight(buffer))
        let scale = min(1.0, longEdgeCap / max(width, height))
        
        func even(_ v: CGFloat) -> Int { let i = max(2, Int(v * scale)); return i - (i & 1) }
        return CGSize(width: even(width), height: even(height))
    }

    private static func downsample(_ buffer: CVPixelBuffer, to size: CGSize,
                                   using ciContext: CIContext) -> CVPixelBuffer {
        let width = Int(size.width)
        let height = Int(size.height)
        var output: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
        ]
        CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                            kCVPixelFormatType_32BGRA, attrs as CFDictionary, &output)
        guard let target = output else { return buffer }
        let sx = size.width / CGFloat(CVPixelBufferGetWidth(buffer))
        let sy = size.height / CGFloat(CVPixelBufferGetHeight(buffer))
        let ci = CIImage(cvPixelBuffer: buffer)
            .transformed(by: CGAffineTransform(scaleX: sx, y: sy))
        ciContext.render(ci, to: target)
        return target
    }
}

struct VideoExportService {
    func encode(totalFrames: Int, size: CGSize, fps: Int,
                frameProvider: @escaping @Sendable (Int) throws -> CGImage,
                onProgress: (@Sendable (Double) -> Void)? = nil) async throws -> URL {

        let width = Int(size.width)
        let height = Int(size.height)
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("buildup-\(UUID().uuidString).mov")

        return try await Task.detached(priority: .userInitiated) {
            try? FileManager.default.removeItem(at: outputURL) 

            guard let writer = try? AVAssetWriter(outputURL: outputURL, fileType: .mov) else {
                throw VideoExportError.writerSetupFailed
            }

            let videoSettings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: Int(Double(width * height) * Double(fps) * 6),
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                    AVVideoMaxKeyFrameIntervalKey: fps
                ],

                AVVideoColorPropertiesKey: [
                    AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                    AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                    AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
                ]
            ]

            let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
            input.expectsMediaDataInRealTime = false
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: input,
                sourcePixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferWidthKey as String: width,
                    kCVPixelBufferHeightKey as String: height,
                    kCVPixelBufferIOSurfacePropertiesKey as String: [:]
                ])


            guard writer.canAdd(input) else { throw VideoExportError.writerSetupFailed }
            writer.add(input)
            guard writer.startWriting() else {
                throw VideoExportError.finalizeFailed(writer.error?.localizedDescription ?? "unknown")
            }

            writer.startSession(atSourceTime: .zero)

            guard let pool = adaptor.pixelBufferPool else {
                writer.cancelWriting()
                throw VideoExportError.pixelBufferPoolUnavailable
            }

            for i in 0..<totalFrames {
                let image = try frameProvider(i)
                while !input.isReadyForMoreMediaData {
                    try await Task.sleep(for: .milliseconds(5))
                }
                let buffer = try Self.pixelBuffer(from: image, pool: pool,
                                                  width: width, height: height)
                                                  
                let time = CMTime(value: Int64(i), timescale: Int32(fps))

                guard adaptor.append(buffer, withPresentationTime: time) else {
                    writer.cancelWriting()
                    throw VideoExportError.appendFailed
                }
                onProgress?(Double(i + 1) / Double(totalFrames))
            }

            input.markAsFinished()
            await writer.finishWriting()
            guard writer.status == .completed else {
                throw VideoExportError.finalizeFailed(writer.error?.localizedDescription ?? "unknown")
            }

            return outputURL
        }.value
    }


    private static func pixelBuffer(from image: CGImage, pool: CVPixelBufferPool,
                                    width: Int, height: Int) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer) == kCVReturnSuccess,
              let pixelBuffer = buffer else {
            throw VideoExportError.pixelBufferCreationFailed
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: base,
                width: width, height: height,
                bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue) else {
            throw VideoExportError.pixelBufferCreationFailed

        }

        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return pixelBuffer
    }
}
