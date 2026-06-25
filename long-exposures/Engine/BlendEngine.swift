//
//  BlendEngine.swift
//  long-exposures
//
//  Phase 2: the core. Reduces N frames into one long-exposure image with a
//  selectable blend mode, accumulating in linear light in a float32 texture.
//
//  Pipeline per blend:
//    1. Allocate a float32 RGBA accumulator at the frame size.
//    2. Seed it (zero for average, first frame for lighten/darken).
//    3. For each frame: upload BGRA -> Metal texture, run the accumulate kernel.
//    4. Resolve the accumulator to an sRGB BGRA8 texture and read back a CGImage.
//

import Foundation
import Metal
import CoreVideo
import CoreImage

enum BlendMode: String, CaseIterable {
    case average
    case lighten
    case darken

    var kernelName: String {
        switch self {
        case .average: return "accumulate_average"
        case .lighten: return "accumulate_lighten"
        case .darken:  return "accumulate_darken"
        }
    }

    /// Whether the resolve step divides the accumulator by the frame count.
    var dividesByCount: Bool { self == .average }

    /// Lighten/darken seed the accumulator with the first frame rather than zero.
    var seedsWithFirstFrame: Bool { self != .average }
}

enum BlendError: LocalizedError {
    case metalUnavailable
    case libraryLoadFailed
    case kernelNotFound(String)
    case textureAllocationFailed
    case noFrames
    case commandEncodingFailed
    case imageReadbackFailed

    var errorDescription: String? {
        switch self {
        case .metalUnavailable:      return "No Metal device available."
        case .libraryLoadFailed:     return "Could not load the Metal shader library."
        case .kernelNotFound(let n): return "Compute kernel '\(n)' not found."
        case .textureAllocationFailed: return "Failed to allocate a Metal texture."
        case .noFrames:              return "No frames to blend."
        case .commandEncodingFailed: return "Failed to encode Metal commands."
        case .imageReadbackFailed:   return "Failed to read the blended image back from the GPU."
        }
    }
}

final class BlendEngine {

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let library: MTLLibrary
    private let textureCache: CVMetalTextureCache
    private let ciContext: CIContext

    private var accumulatePipelines: [String: MTLComputePipelineState] = [:]
    private var resolvePipeline: MTLComputePipelineState!

    /// Caches rendered results so revisiting a range during a drag is instant.
    /// Keyed by mode + range + frame-set identity. Bounded; oldest entries drop.
    private struct CacheKey: Hashable {
        let mode: String
        let lowerBound: Int
        let upperBound: Int
        let generation: Int
    }
    private var resultCache: [CacheKey: CGImage] = [:]
    private var cacheOrder: [CacheKey] = []
    private let cacheLimit = 64
    /// Bumped whenever the frame set changes so stale cache entries can't collide.
    private var generation = 0

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw BlendError.metalUnavailable }
        guard let queue = device.makeCommandQueue() else { throw BlendError.metalUnavailable }
        guard let library = device.makeDefaultLibrary() else { throw BlendError.libraryLoadFailed }

        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        guard let textureCache = cache else { throw BlendError.textureAllocationFailed }

        self.device = device
        self.commandQueue = queue
        self.library = library
        self.textureCache = textureCache
        self.ciContext = CIContext(mtlDevice: device)

        self.resolvePipeline = try makePipeline(named: "resolve")
    }

    private func makePipeline(named name: String) throws -> MTLComputePipelineState {
        guard let function = library.makeFunction(name: name) else {
            throw BlendError.kernelNotFound(name)
        }
        return try device.makeComputePipelineState(function: function)
    }

    private func accumulatePipeline(for mode: BlendMode) throws -> MTLComputePipelineState {
        if let cached = accumulatePipelines[mode.kernelName] { return cached }
        let pipeline = try makePipeline(named: mode.kernelName)
        accumulatePipelines[mode.kernelName] = pipeline
        return pipeline
    }

    /// Call when the underlying frame set changes (new import) so cached results
    /// for the previous frames are never returned for the new ones.
    func invalidateCache() {
        generation += 1
        resultCache.removeAll(keepingCapacity: true)
        cacheOrder.removeAll(keepingCapacity: true)
    }

    /// Blends a contiguous range of frames, caching the result per (mode, range).
    /// Used by the interactive editor: dragging back to a prior range is instant.
    func blend(frames: [CVPixelBuffer], range: ClosedRange<Int>, mode: BlendMode) throws -> CGImage {
        guard !frames.isEmpty else { throw BlendError.noFrames }
        let lower = max(0, range.lowerBound)
        let upper = min(frames.count - 1, range.upperBound)
        guard lower <= upper else { throw BlendError.noFrames }

        let key = CacheKey(mode: mode.kernelName, lowerBound: lower, upperBound: upper, generation: generation)
        if let cached = resultCache[key] { return cached }

        let image = try blend(frames: Array(frames[lower...upper]), mode: mode)
        store(image, for: key)
        return image
    }

    private func store(_ image: CGImage, for key: CacheKey) {
        resultCache[key] = image
        cacheOrder.append(key)
        if cacheOrder.count > cacheLimit {
            let evicted = cacheOrder.removeFirst()
            resultCache.removeValue(forKey: evicted)
        }
    }

    /// Blends the given BGRA frames into a single long-exposure CGImage.
    func blend(frames: [CVPixelBuffer], mode: BlendMode) throws -> CGImage {
        guard let first = frames.first else { throw BlendError.noFrames }

        let width = CVPixelBufferGetWidth(first)
        let height = CVPixelBufferGetHeight(first)

        let accumulator = try makeAccumulator(width: width, height: height)
        let accumulatePipeline = try accumulatePipeline(for: mode)

        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw BlendError.commandEncodingFailed
        }

        // Seed lighten/darken with the first frame so max/min start from real data
        // (a zero seed would pin darken to black and bias lighten). Average starts
        // from the zero-filled accumulator and includes every frame below.
        let framesToAccumulate: ArraySlice<CVPixelBuffer>
        if mode.seedsWithFirstFrame {
            try seed(accumulator: accumulator, with: first, on: commandBuffer)
            framesToAccumulate = frames[1...]
        } else {
            framesToAccumulate = frames[0...]
        }

        for frame in framesToAccumulate {
            guard let frameTexture = makeReadTexture(from: frame) else {
                throw BlendError.textureAllocationFailed
            }
            guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
                throw BlendError.commandEncodingFailed
            }
            encoder.setComputePipelineState(accumulatePipeline)
            encoder.setTexture(frameTexture, index: 0)
            encoder.setTexture(accumulator, index: 1)
            dispatch(encoder, pipeline: accumulatePipeline, width: width, height: height)
            encoder.endEncoding()
        }

        let output = try makeOutputTexture(width: width, height: height)
        try encodeResolve(accumulator: accumulator, output: output, mode: mode, on: commandBuffer)

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        if commandBuffer.error != nil {
            throw BlendError.commandEncodingFailed
        }

        return try cgImage(from: output)
    }

    // MARK: - Seeding (lighten/darken)

    private func seed(accumulator: MTLTexture, with frame: CVPixelBuffer, on commandBuffer: MTLCommandBuffer) throws {
        // The accumulator is zero-cleared and linear frame values are >= 0, so running the
        // lighten (max) kernel once writes the first frame's linear values verbatim. Both
        // lighten and darken use this to start max/min from real data rather than 0.
        guard let frameTexture = makeReadTexture(from: frame) else {
            throw BlendError.textureAllocationFailed
        }
        let pipeline = try accumulatePipeline(for: .lighten)
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw BlendError.commandEncodingFailed
        }
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(frameTexture, index: 0)
        encoder.setTexture(accumulator, index: 1)
        dispatch(encoder, pipeline: pipeline, width: accumulator.width, height: accumulator.height)
        encoder.endEncoding()
    }

    // MARK: - Resolve

    private func encodeResolve(accumulator: MTLTexture, output: MTLTexture, mode: BlendMode, on commandBuffer: MTLCommandBuffer) throws {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw BlendError.commandEncodingFailed
        }
        encoder.setComputePipelineState(resolvePipeline)
        encoder.setTexture(accumulator, index: 0)
        encoder.setTexture(output, index: 1)
        var divide: UInt32 = mode.dividesByCount ? 1 : 0
        encoder.setBytes(&divide, length: MemoryLayout<UInt32>.size, index: 0)
        dispatch(encoder, pipeline: resolvePipeline, width: output.width, height: output.height)
        encoder.endEncoding()
    }

    // MARK: - Dispatch helper

    private func dispatch(_ encoder: MTLComputeCommandEncoder, pipeline: MTLComputePipelineState, width: Int, height: Int) {
        let w = pipeline.threadExecutionWidth
        let h = max(1, pipeline.maxTotalThreadsPerThreadgroup / w)
        let threadsPerGroup = MTLSize(width: w, height: h, depth: 1)
        let groups = MTLSize(width: (width + w - 1) / w,
                             height: (height + h - 1) / h,
                             depth: 1)
        encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: threadsPerGroup)
    }

    // MARK: - Texture allocation

    private func makeAccumulator(width: Int, height: Int) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba32Float, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .private
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw BlendError.textureAllocationFailed
        }
        // float32 .private textures are not guaranteed zero-initialized; clear via a render-free blit.
        try clearToZero(texture)
        return texture
    }

    private func clearToZero(_ texture: MTLTexture) throws {
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let blit = commandBuffer.makeBlitCommandEncoder() else {
            throw BlendError.commandEncodingFailed
        }
        let bytesPerRow = texture.width * MemoryLayout<Float>.size * 4
        let length = bytesPerRow * texture.height
        guard let zeroBuffer = device.makeBuffer(length: length, options: .storageModeShared) else {
            throw BlendError.textureAllocationFailed
        }
        memset(zeroBuffer.contents(), 0, length)
        blit.copy(from: zeroBuffer, sourceOffset: 0,
                  sourceBytesPerRow: bytesPerRow, sourceBytesPerImage: length,
                  sourceSize: MTLSize(width: texture.width, height: texture.height, depth: 1),
                  to: texture, destinationSlice: 0, destinationLevel: 0,
                  destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }

    private func makeOutputTexture(width: Int, height: Int) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderWrite, .shaderRead]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw BlendError.textureAllocationFailed
        }
        return texture
    }

    /// Wraps a BGRA CVPixelBuffer as a Metal texture without copying.
    private func makeReadTexture(from buffer: CVPixelBuffer) -> MTLTexture? {
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, buffer, nil,
            .bgra8Unorm, width, height, 0, &cvTexture)
        guard status == kCVReturnSuccess, let cvTexture,
              let texture = CVMetalTextureGetTexture(cvTexture) else {
            return nil
        }
        return texture
    }

    /// Renders one frame to a CGImage through the same pipeline as the blend, so its
    /// orientation matches a blended result. Used by the before/after compare view.
    /// A one-frame average is just the frame itself.
    func render(frame: CVPixelBuffer) throws -> CGImage {
        try blend(frames: [frame], mode: .average)
    }

    // MARK: - Readback

    private func cgImage(from texture: MTLTexture) throws -> CGImage {
        let ciImage = CIImage(mtlTexture: texture, options: [.colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])
        guard let ciImage else { throw BlendError.imageReadbackFailed }
        // Metal textures are top-left origin; CIImage is bottom-left. Flip vertically.
        let flipped = ciImage.transformed(by: CGAffineTransform(scaleX: 1, y: -1)
            .translatedBy(x: 0, y: -ciImage.extent.height))
        guard let cg = ciContext.createCGImage(flipped, from: flipped.extent) else {
            throw BlendError.imageReadbackFailed
        }
        return cg
    }
}
