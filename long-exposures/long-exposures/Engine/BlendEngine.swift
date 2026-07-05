//
//  BlendEngine.swift
//  long-exposures
//
//  The core blend engine
//

import Foundation
import Metal
import CoreVideo
import CoreImage

enum BlendMode: String, CaseIterable {
    case average
    case lighten
    case darken

    var bias: Float {
        switch self {
        case .average: return 0
        case .lighten: return 1
        case .darken:  return -1
        }
    }
}

/// Everything the engine needs to smooth motion for a blend.
struct BlendInterpolation {
    let flows: [FlowField?]
    let shakeDeltas: [SIMD2<Float>]

    ///Hard cap on synthesized samples per gap to prevent stalling
    static let maxSamplesPerGap = 15
    static let targetStepPixels: Float = 8

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
        case .metalUnavailable: return "No Metal device available."
        case .libraryLoadFailed: return "Could not load the Metal shader library."
        case .kernelNotFound(let n): return "Compute kernel '\(n)' not found."
        case .textureAllocationFailed: return "Failed to allocate a Metal texture."
        case .noFrames: return "No frames to blend."
        case .commandEncodingFailed: return "Failed to encode Metal commands."
        case .imageReadbackFailed: return "Failed to read the blended image back from the GPU."
        }
    }
}

final class BlendAccumulator {
    let width: Int
    let height: Int
    let minTex: MTLTexture
    let maxTex: MTLTexture
    let sumTex: MTLTexture

    fileprivate(set) var frameCount = 0

    fileprivate init(width: Int, height: Int,
                     minTex: MTLTexture, maxTex: MTLTexture, sumTex: MTLTexture) {
        self.width = width
        self.height = height
        self.minTex = minTex
        self.maxTex = maxTex
        self.sumTex = sumTex
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

    private struct WarpParams {
        var t: Float
        var flowScale: Float
        var shakeDelta: SIMD2<Float>
    }

    private static let minSeed: Float = 1e9
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
    private var generation = 0
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
    func invalidateCache() {
        generation += 1
        resultCache.removeAll(keepingCapacity: true)
        cacheOrder.removeAll(keepingCapacity: true)
    }

    /// blends a range of frames
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

    /// blends the bgra frames into a long-exposure img
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

        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw BlendError.commandEncodingFailed
        }

        var dispatchedAny = false
        for (index, frame) in frames.enumerated() {
            let next = index + 1 < frames.count ? frames[index + 1] : nil
            let flow = interpolation.flatMap { index < $0.flows.count ? $0.flows[index] : nil }
            let shakeDelta = interpolation.flatMap {
                index < $0.shakeDeltas.count ? $0.shakeDeltas[index] : nil
            } ?? .zero
            try encodeAccumulate(frame: frame, next: next, flow: flow, shakeDelta: shakeDelta,
                                 width: width, height: height,
                                 minTex: minTex, maxTex: maxTex, sumTex: sumTex,
                                 on: encoder, barrierBefore: dispatchedAny)
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

    /// create build up video
    func makeAccumulator(width: Int, height: Int) throws -> BlendAccumulator {
        let minTex = try makeAccumulator(width: width, height: height, fill: Self.minSeed)
        let maxTex = try makeAccumulator(width: width, height: height, fill: 0)
        let sumTex = try makeAccumulator(width: width, height: height, fill: 0)

        return BlendAccumulator(width: width, height: height,
                                minTex: minTex, maxTex: maxTex, sumTex: sumTex)
    }

    func accumulate(_ frame: CVPixelBuffer, next: CVPixelBuffer?, flow: FlowField?,
                    shakeDelta: SIMD2<Float>, into acc: BlendAccumulator) throws {
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw BlendError.commandEncodingFailed
        }

        try encodeAccumulate(frame: frame, next: next, flow: flow, shakeDelta: shakeDelta,
                             width: acc.width, height: acc.height,
                             minTex: acc.minTex, maxTex: acc.maxTex, sumTex: acc.sumTex,
                             on: encoder, barrierBefore: false)
        encoder.endEncoding()

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        if commandBuffer.error != nil { throw BlendError.commandEncodingFailed }
        acc.frameCount += 1
    }

    func resolve(_ acc: BlendAccumulator, bias: Float) throws -> CGImage {
        guard acc.frameCount > 0 else { throw BlendError.noFrames }
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw BlendError.commandEncodingFailed
        }
        
        let output = try makeOutputTexture(width: acc.width, height: acc.height)
        try encodeResolve(minTex: acc.minTex, maxTex: acc.maxTex, sumTex: acc.sumTex,
                          output: output, bias: bias, on: commandBuffer)


        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        if commandBuffer.error != nil { throw BlendError.commandEncodingFailed }
        return try cgImage(from: output)
    }

    private func encodeAccumulate(frame: CVPixelBuffer, next: CVPixelBuffer?,
                                  flow: FlowField?, shakeDelta: SIMD2<Float>,
                                  width: Int, height: Int,
                                  minTex: MTLTexture, maxTex: MTLTexture, sumTex: MTLTexture,
                                  on encoder: MTLComputeCommandEncoder,
                                  barrierBefore: Bool) throws {
        guard let frameTexture = makeReadTexture(from: frame) else {
            throw BlendError.textureAllocationFailed
        }
        if barrierBefore { encoder.memoryBarrier(scope: .textures) }

        encoder.setComputePipelineState(accumulatePipeline)
        encoder.setTexture(frameTexture, index: 0)
        encoder.setTexture(minTex, index: 1)
        encoder.setTexture(maxTex, index: 2)
        encoder.setTexture(sumTex, index: 3)

        dispatch(encoder, pipeline: accumulatePipeline, width: width, height: height)

        guard let next, let flow,
              let flowTexture = makeFlowTexture(from: flow.buffer),
              let nextTexture = makeReadTexture(from: next)
        else { return }

        let flowScale = Float(width) / Float(flow.measuredWidth)
        let samples = Self.sampleCount(for: flow, flowScale: flowScale)

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

    private static func sampleCount(for flow: FlowField, flowScale: Float) -> Int {
        guard flow.maxMagnitude.isFinite, flowScale.isFinite, flowScale > 0 else { return 1 }
        let magnitude = flow.maxMagnitude * flowScale
        let ideal = Int((magnitude / BlendInterpolation.targetStepPixels).rounded(.up)) - 1
        return min(BlendInterpolation.maxSamplesPerGap, max(1, ideal))
    }

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

    private func dispatch(_ encoder: MTLComputeCommandEncoder, pipeline: MTLComputePipelineState, width: Int, height: Int) {
        let w = pipeline.threadExecutionWidth
        let h = max(1, pipeline.maxTotalThreadsPerThreadgroup / w)
        let threadsPerGroup = MTLSize(width: w, height: h, depth: 1)
        let groups = MTLSize(width: (width + w - 1) / w,
                             height: (height + h - 1) / h,
                             depth: 1)
        encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: threadsPerGroup)
    }

    private func makeAccumulator(width: Int, height: Int, fill: Float) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba32Float, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .private
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw BlendError.textureAllocationFailed
        }
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



    /// renders one frame for for the before state
    func render(frame: CVPixelBuffer) throws -> CGImage {
        try blend(frames: [frame], bias: 0)
    }

    private func cgImage(from texture: MTLTexture) throws -> CGImage {
        let ciImage = CIImage(mtlTexture: texture, options: [.colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])
        guard let ciImage else { throw BlendError.imageReadbackFailed }


        let flipped = ciImage.transformed(by: CGAffineTransform(scaleX: 1, y: -1)
            .translatedBy(x: 0, y: -ciImage.extent.height))
        guard let cg = ciContext.createCGImage(flipped, from: flipped.extent) else {
            throw BlendError.imageReadbackFailed
        }
        return cg
    }
}
