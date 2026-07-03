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

/// Everything the engine needs to synthesize intermediate samples ("smooth
/// motion") for one blend. Entry i of `flows` is the flow for the gap between
/// frames i and i+1 of the frame array the blend receives; nil entries skip
/// synthesis for that gap. Never carries pixel data for the synthesized frames
/// themselves — they are warped straight into the accumulators on the GPU.
struct BlendInterpolation {
    let flows: [FlowField?]
    /// Per-gap registration shake correction (transform[i+1] applied minus
    /// transform[i] applied, expressed as the raw-flow component to subtract),
    /// in pixels at the flow's measured resolution. Empty when alignment is off.
    let shakeDeltas: [SIMD2<Float>]

    /// Hard cap on synthesized samples per gap, so a degenerate flow estimate
    /// can't stall a blend. Bounds a full-res export at ~15 extra dispatches
    /// per fast gap; at the cap a 240-output-px streak still closes to ~15 px
    /// steps, which linear-filtered sampling blurs over.
    static let maxSamplesPerGap = 15
    /// Target spacing between temporal samples, in pixels *at the resolution
    /// being blended* (flow magnitudes are rescaled by flowScale before the
    /// division). Perceived gap size scales with output resolution — a step
    /// that looks continuous in a 720 px preview is a visible stutter in a
    /// 4032 px export — so the density must be computed in output pixels.
    static let targetStepPixels: Float = 8

    /// Payload for a slice `range` of the frame array this payload was built
    /// for: frames lower...upper have gaps lower..<upper.
    func sliced(to range: ClosedRange<Int>) -> BlendInterpolation {
        guard range.lowerBound < range.upperBound,
              range.lowerBound >= 0, range.upperBound <= flows.count else {
            return BlendInterpolation(flows: [], shakeDeltas: [])
        }
        let gaps = range.lowerBound..<range.upperBound
        return BlendInterpolation(
            flows: Array(flows[gaps]),
            shakeDeltas: shakeDeltas.isEmpty ? [] : Array(shakeDeltas[gaps]))
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
    private var interpolatePipeline: MTLComputePipelineState!
    private var resolvePipeline: MTLComputePipelineState!

    /// Mirrors `WarpParams` in BlendKernels.metal: float, float, float2 — the
    /// float2's 8-byte alignment makes both layouts 16 bytes.
    private struct WarpParams {
        var t: Float
        var flowScale: Float
        var shakeDelta: SIMD2<Float>
    }

    /// Seed value for the min accumulator: larger than any linear colour (which is
    /// in [0,1] after sRGB->linear), so the first real value always wins the min.
    private static let minSeed: Float = 1e9

    /// Caches rendered results so revisiting a range during a drag is instant.
    /// Keyed by quantized bias + range + frame-set identity. Bounded; oldest drop.
    private struct CacheKey: Hashable {
        let biasBucket: Int
        let lowerBound: Int
        let upperBound: Int
        let interpolated: Bool
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
        self.interpolatePipeline = try makePipeline(named: "accumulateInterpolated")
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
    /// `interpolation`, when present, must cover the *full* frame array — it is
    /// sliced here alongside the frames.
    func blend(frames: [CVPixelBuffer], range: ClosedRange<Int>, bias: Float,
               interpolation: BlendInterpolation? = nil) throws -> CGImage {
        guard !frames.isEmpty else { throw BlendError.noFrames }
        let lower = max(0, range.lowerBound)
        let upper = min(frames.count - 1, range.upperBound)
        guard lower <= upper else { throw BlendError.noFrames }

        let sliced = interpolation?.sliced(to: lower...upper)
        let key = CacheKey(biasBucket: Self.biasBucket(bias),
                           lowerBound: lower, upperBound: upper,
                           interpolated: sliced != nil, generation: generation)
        if let cached = resultCache[key] { return cached }

        let image = try blend(frames: Array(frames[lower...upper]), bias: bias, interpolation: sliced)
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
    /// `interpolation`, when present, must be 1:1 with `frames`' gaps
    /// (flows.count == frames.count - 1): each gap with a flow field gets
    /// synthesized in-between samples warped into the accumulators.
    func blend(frames: [CVPixelBuffer], bias: Float,
               interpolation: BlendInterpolation? = nil) throws -> CGImage {
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

        var dispatchedAny = false
        for (index, frame) in frames.enumerated() {
            guard let frameTexture = makeReadTexture(from: frame) else {
                throw BlendError.textureAllocationFailed
            }
            if dispatchedAny {
                encoder.memoryBarrier(scope: .textures)
            }
            encoder.setComputePipelineState(accumulatePipeline)
            encoder.setTexture(frameTexture, index: 0)
            encoder.setTexture(minTex, index: 1)
            encoder.setTexture(maxTex, index: 2)
            encoder.setTexture(sumTex, index: 3)
            dispatch(encoder, pipeline: accumulatePipeline, width: width, height: height)
            dispatchedAny = true

            // Fill the temporal gap to the next frame with synthesized samples,
            // warped along the pair's optical flow straight into the same
            // accumulators. A missing flow just leaves that gap unsynthesized.
            guard let interpolation, index < interpolation.flows.count,
                  index + 1 < frames.count,
                  let flow = interpolation.flows[index],
                  let flowTexture = makeFlowTexture(from: flow.buffer),
                  let nextTexture = makeReadTexture(from: frames[index + 1])
            else { continue }

            let flowScale = Float(width) / Float(flow.measuredWidth)
            let samples = Self.sampleCount(for: flow, flowScale: flowScale)
            let shakeDelta = index < interpolation.shakeDeltas.count
                ? interpolation.shakeDeltas[index] : SIMD2<Float>.zero

            encoder.setComputePipelineState(interpolatePipeline)
            encoder.setTexture(frameTexture, index: 0)
            encoder.setTexture(nextTexture, index: 1)
            encoder.setTexture(flowTexture, index: 2)
            encoder.setTexture(minTex, index: 3)
            encoder.setTexture(maxTex, index: 4)
            encoder.setTexture(sumTex, index: 5)
            for k in 1...samples {
                encoder.memoryBarrier(scope: .textures)
                var params = WarpParams(
                    t: Float(k) / Float(samples + 1),
                    flowScale: flowScale,
                    shakeDelta: shakeDelta)
                encoder.setBytes(&params, length: MemoryLayout<WarpParams>.stride, index: 0)
                dispatch(encoder, pipeline: interpolatePipeline, width: width, height: height)
            }
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

    /// Synthesized samples for one gap: enough that consecutive temporal
    /// samples land ~targetStepPixels apart along the fastest motion in the
    /// gap, *measured at the resolution being blended* (flowScale converts the
    /// flow-resolution magnitude), capped so a degenerate flow estimate can't
    /// stall a blend, floored at 1 so every gap gets at least a midpoint.
    private static func sampleCount(for flow: FlowField, flowScale: Float) -> Int {
        guard flow.maxMagnitude.isFinite, flowScale.isFinite, flowScale > 0 else { return 1 }
        let magnitude = flow.maxMagnitude * flowScale
        let ideal = Int((magnitude / BlendInterpolation.targetStepPixels).rounded(.up)) - 1
        return min(BlendInterpolation.maxSamplesPerGap, max(1, ideal))
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

    /// Wraps a TwoComponent16Half flow buffer as an rg16Float Metal texture
    /// without copying. Sibling of `makeReadTexture(from:)`.
    private func makeFlowTexture(from buffer: CVPixelBuffer) -> MTLTexture? {
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, buffer, nil,
            .rg16Float, width, height, 0, &cvTexture)
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
