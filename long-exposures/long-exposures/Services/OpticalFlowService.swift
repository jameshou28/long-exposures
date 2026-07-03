//
//  OpticalFlowService.swift
//  long-exposures
//
//  Dense optical flow between consecutive frames to synthesize intermediate samples during blend  for smoothed motion 
//

import Foundation
import Vision
import CoreImage
import CoreVideo

nonisolated struct FlowField: @unchecked Sendable {
    let buffer: CVPixelBuffer
    let measuredWidth: CGFloat
    let maxMagnitude: Float
}

nonisolated struct OpticalFlowService: Sendable {
    static let flowLongEdge: CGFloat = 360

    func flows(for frames: [CVPixelBuffer], using context: CIContext) -> [FlowField?] {
        guard frames.count > 1 else { return [] }
        // downsample each frame once
        let small = frames.map { downsample($0, using: context) }
        let fields = (0..<(frames.count - 1)).map { flow(from: small[$0], to: small[$0 + 1]) }
        return fields
    }

    func flowsOffActor(for frames: [CVPixelBuffer], using context: CIContext) async -> [FlowField?] {
        let box = PixelBufferBox(buffers: frames)
        return await Task.detached(priority: .userInitiated) {
            self.flows(for: box.buffers, using: context)
        }.value
    }

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

    // downsample func
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
