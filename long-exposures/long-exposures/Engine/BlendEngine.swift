//
//  BlendEngine.swift
//  long-exposures
//
//  The core blend engine. Reduces N frames into one long-exposure image,
//  accumulating in linear light in float32 textures.
//
//  The blend is a continuous slider rather than discrete modes: a single pass
//  accumulates the running min, max, and average of every frame at once, and a
//  signed `bias` in [-1, +1] picks where to land — toward the min (darken) on
//  the negative side, toward the max (lighten) on the positive side, plain
//  average at 0.
//
//  Pipeline per blend:
//    1. Allocate min/max/sum float32 accumulators at the frame size.
//    2. Seed them (min -> large, max/sum -> zero).
//    3. For each frame: upload BGRA -> Metal texture, run the accumulate kernel,
//       with a memory barrier between frames so the read-modify-write chain runs
//       in order (separate dispatches on a shared read_write texture otherwise race).
//    4. Resolve to an sRGB BGRA8 texture with the chosen bias and read back a CGImage.
//

import Foundation
import Metal
import CoreVideo
import CoreImage

enum BlendMode: String, CaseIterable {
    case average
    case lighten
    case darken

    /// Signed bias on the darken<->average<->lighten axis for this discrete mode.
    /// The slider uses these as anchors; the value persists for saved exposures.
    var bias: Float {
        switch self {
        case .average: return 0
        case .lighten: return 1
        case .darken:  return -1
        }
    }
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

    private var accumulatePipeline: MTLComputePipelineState!
    private var resolvePipeline: MTLComputePipelineState!

    /// Seed value for the min accumulator: larger than any linear colour (which is
    /// in [0,1] after sRGB->linear), so the first real value always wins the min.
    private static let minSeed: Float = 1e9

    /// Caches rendered results so revisiting a range during a drag is instant.
    /// Keyed by quantized bias + range + frame-set identity. Bounded; oldest drop.
    private struct CacheKey: Hashable {
        let biasBucket: Int
        let lowerBound: Int
        let upperBound: Int
        let generation: Int
    }
    private var resultCache: [CacheKey: CGImage] = [:]
    private var cacheOrder: [CacheKey] = []
    private let cacheLimit = 64
    /// Bumped whenever the frame set changes so stale cache entries can't collide.
    private var generation = 0

    /// Bias is continuous; bucket it so near-identical slider positions share a
    /// cache entry (and so float keys stay stable). 100 buckets over [-1, +1].
    private static func biasBucket(_ bias: Float) -> Int {
        Int((min(max(bias, -1), 1) * 50).rounded())
    }

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

        self.accumulatePipeline = try makePipeline(named: "accumulate")
        self.resolvePipeline = try makePipeline(named: "resolve")
    }

    private func makePipeline(named name: String) throws -> MTLComputePipelineState {
        guard let function = library.makeFunction(name: name) else {
            throw BlendError.kernelNotFound(name)
        }
        return try device.makeComputePipelineState(function: function)
    }

    /// Call when the underlying frame set changes (new import) so cached results
    /// for the previous frames are never returned for the new ones.
    func invalidateCache() {
        generation += 1
        resultCache.removeAll(keepingCapacity: true)
        cacheOrder.removeAll(keepingCapacity: true)
    }

    /// Blends a contiguous range of frames, caching the result per (bias, range).
    /// Used by the interactive editor: dragging back to a prior range is instant.
    func blend(frames: [CVPixelBuffer], range: ClosedRange<Int>, bias: Float) throws -> CGImage {
        guard !frames.isEmpty else { throw BlendError.noFrames }
        let lower = max(0, range.lowerBound)
        let upper = min(frames.count - 1, range.upperBound)
        guard lower <= upper else { throw BlendError.noFrames }

        let key = CacheKey(biasBucket: Self.biasBucket(bias),
                           lowerBound: lower, upperBound: upper, generation: generation)
        if let cached = resultCache[key] { return cached }

        let image = try blend(frames: Array(frames[lower...upper]), bias: bias)
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

    /// Blends the given BGRA frames into a single long-exposure CGImage at `bias`.
    func blend(frames: [CVPixelBuffer], bias: Float) throws -> CGImage {
        guard let first = frames.first else { throw BlendError.noFrames }

        let width = CVPixelBufferGetWidth(first)
        let height = CVPixelBufferGetHeight(first)

        let minTex = try makeAccumulator(width: width, height: height, fill: Self.minSeed)
        let maxTex = try makeAccumulator(width: width, height: height, fill: 0)
        let sumTex = try makeAccumulator(width: width, height: height, fill: 0)

        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw BlendError.commandEncodingFailed
        }

        // All frames accumulate into the same read_write textures, each dispatch
        // reading what the prior one wrote. That read-modify-write chain must run
        // in order: a single encoder with a texture memory barrier between
        // dispatches guarantees each frame's write is visible to the next.
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw BlendError.commandEncodingFailed
        }
        encoder.setComputePipelineState(accumulatePipeline)

        var dispatchedAny = false
        for frame in frames {
            guard let frameTexture = makeReadTexture(from: frame) else {
                throw BlendError.textureAllocationFailed
            }
            if dispatchedAny {
                encoder.memoryBarrier(scope: .textures)
            }
            encoder.setTexture(frameTexture, index: 0)
            encoder.setTexture(minTex, index: 1)
            encoder.setTexture(maxTex, index: 2)
            encoder.setTexture(sumTex, index: 3)
            dispatch(encoder, pipeline: accumulatePipeline, width: width, height: height)
            dispatchedAny = true
        }
        encoder.endEncoding()

        let output = try makeOutputTexture(width: width, height: height)
        try encodeResolve(minTex: minTex, maxTex: maxTex, sumTex: sumTex,
                          output: output, bias: bias, on: commandBuffer)

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        if commandBuffer.error != nil {
            throw BlendError.commandEncodingFailed
        }

        return try cgImage(from: output)
    }

    // MARK: - Resolve

    private func encodeResolve(minTex: MTLTexture, maxTex: MTLTexture, sumTex: MTLTexture,
                               output: MTLTexture, bias: Float, on commandBuffer: MTLCommandBuffer) throws {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw BlendError.commandEncodingFailed
        }
        encoder.setComputePipelineState(resolvePipeline)
        encoder.setTexture(minTex, index: 0)
        encoder.setTexture(maxTex, index: 1)
        encoder.setTexture(sumTex, index: 2)
        encoder.setTexture(output, index: 3)
        var b = min(max(bias, -1), 1)
        encoder.setBytes(&b, length: MemoryLayout<Float>.size, index: 0)
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

    private func makeAccumulator(width: Int, height: Int, fill: Float) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba32Float, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .private
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw BlendError.textureAllocationFailed
        }
        // float32 .private textures are not guaranteed initialized; seed via a blit.
        try fillTexture(texture, with: fill)
        return texture
    }

    private func fillTexture(_ texture: MTLTexture, with value: Float) throws {
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let blit = commandBuffer.makeBlitCommandEncoder() else {
            throw BlendError.commandEncodingFailed
        }
        let bytesPerRow = texture.width * MemoryLayout<Float>.size * 4
        let length = bytesPerRow * texture.height
        guard let seedBuffer = device.makeBuffer(length: length, options: .storageModeShared) else {
            throw BlendError.textureAllocationFailed
        }
        if value == 0 {
            memset(seedBuffer.contents(), 0, length)
        } else {
            let floats = seedBuffer.contents().bindMemory(to: Float.self, capacity: length / MemoryLayout<Float>.size)
            for i in 0..<(length / MemoryLayout<Float>.size) { floats[i] = value }
        }
        blit.copy(from: seedBuffer, sourceOffset: 0,
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
    /// A one-frame blend at bias 0 is just the frame itself.
    func render(frame: CVPixelBuffer) throws -> CGImage {
        try blend(frames: [frame], bias: 0)
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
