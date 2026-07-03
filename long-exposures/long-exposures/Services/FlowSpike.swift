//
//  FlowSpike.swift
//  long-exposures
//
//  TEMPORARY diagnostic harness for the smooth-motion feature. Launch the app
//  with the --flow-spike argument (simulator is fine — frames are synthesized
//  in code, no camera or Live Photo needed) and it writes blends of a moving
//  square, with and without interpolation, plus the t=0.5 intermediate frame
//  and a report, into tmp/flowspike/. Delete this file once verified.
//

#if DEBUG

import Foundation
import CoreVideo
import CoreGraphics
import CoreImage
import Vision
import UIKit

enum FlowSpike {

    static func runIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("--flow-spike") else { return }
        Task { @MainActor in
            do { try await run() } catch {
                NSLog("FLOWSPIKE failed: \(String(describing: error))")
            }
        }
    }

    @MainActor
    private static func run() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("flowspike")
        try? FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let engine = try BlendEngine()
        let service = OpticalFlowService()
        let ciContext = CIContext()
        var report = ""

        // Moderate motion: 60 px/frame at 720 wide (30 px at flow res).
        try runClip(named: "moderate",
                    positions: stride(from: 60, through: 480, by: 60).map { CGFloat($0) },
                    squareSize: 60,
                    engine: engine, service: service, ciContext: ciContext,
                    directory: directory, report: &report)

        // Fast motion, small subject: 180 px/frame at 720 wide (90 px at flow
        // res) — the scooter-crossing-the-frame case.
        try runClip(named: "fast",
                    positions: [10, 190, 370, 550],
                    squareSize: 40,
                    engine: engine, service: service, ciContext: ciContext,
                    directory: directory, report: &report)

        // GPU-side verification with a hand-built flow field (bypasses Vision,
        // which can't run in the simulator): known displacement, known answer.
        try syntheticFlowTest(engine: engine, directory: directory, report: &report)

        try report.write(to: directory.appendingPathComponent("report.txt"),
                         atomically: true, encoding: .utf8)
        NSLog("FLOWSPIKE done -> \(directory.path)")
    }

    // MARK: - Synthetic flow (ground-truth GPU test)

    /// Two frames whose square moves exactly +120 px in x, plus a fabricated
    /// constant flow field of (+60, 0) at half resolution (measuredWidth 360,
    /// so flowScale 2 reconstructs the 120). Verifies the warp kernel's
    /// direction signs, the flowScale rescale, and the adaptive sample density
    /// with zero dependence on Vision:
    ///   - synthetic-mid.png: square centre must sit at x ≈ 290 (halfway
    ///     between spans 200–260 and 320–380). Doubled/smeared background is
    ///     expected (the fake flow moves everything), ignore it.
    ///   - synthetic-on.png: the red squares must join into one continuous
    ///     streak from x ≈ 200 to 380; synthetic-off.png keeps two copies.
    @MainActor
    private static func syntheticFlowTest(engine: BlendEngine, directory: URL,
                                          report: inout String) throws {
        let width = 720, height = 480
        guard let frameA = makeFrame(width: width, height: height,
                                     squareX: 200, squareY: 210, squareSize: 60),
              let frameB = makeFrame(width: width, height: height,
                                     squareX: 320, squareY: 210, squareSize: 60),
              let flow = makeConstantFlow(width: 360, height: 240, dx: 60, dy: 0) else {
            report += "=== synthetic: SETUP FAILED ===\n"
            return
        }
        report += "=== synthetic: dx 120 px at frame res, constant flow 60 px at 360 wide ===\n"

        let off = try engine.blend(frames: [frameA, frameB], bias: 0)
        try writePNG(off, to: directory.appendingPathComponent("synthetic-off.png"))

        let interpolation = BlendInterpolation(flows: [flow], shakeDeltas: [])
        let on = try engine.blend(frames: [frameA, frameB], bias: 0, interpolation: interpolation)
        try writePNG(on, to: directory.appendingPathComponent("synthetic-on.png"))

        let mid = try engine.renderIntermediate(between: frameA, and: frameB, flow: flow, t: 0.5)
        try writePNG(mid, to: directory.appendingPathComponent("synthetic-mid.png"))
        report += "synthetic-mid: square centre expected at x ≈ 290 of 720\n"
        report += "synthetic-on: expect one continuous red streak x ≈ 200–380\n\n"
    }

    /// A TwoComponent16Half IOSurface-backed buffer filled with a constant
    /// (dx, dy) — the same shape OpticalFlowService produces.
    private static func makeConstantFlow(width: Int, height: Int,
                                         dx: Float, dy: Float) -> FlowField? {
        var out: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: Int(kCVPixelFormatType_TwoComponent16Half),
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
        ]
        CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                            kCVPixelFormatType_TwoComponent16Half, attrs as CFDictionary, &out)
        guard let buffer = out else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let dxHalf = half(from: dx), dyHalf = half(from: dy)
        for row in 0..<height {
            let halves = base.advanced(by: row * rowBytes)
                .bindMemory(to: UInt16.self, capacity: width * 2)
            for x in 0..<width {
                halves[x * 2] = dxHalf
                halves[x * 2 + 1] = dyHalf
            }
        }
        return FlowField(buffer: buffer, measuredWidth: CGFloat(width),
                         maxMagnitude: (dx * dx + dy * dy).squareRoot())
    }

    /// Float -> IEEE 754 half bits. Handles the normal range the spike uses.
    private static func half(from value: Float) -> UInt16 {
        if value == 0 { return 0 }
        let sign: UInt16 = value < 0 ? 0x8000 : 0
        let v = abs(value)
        let exponent = max(-14, min(15, Int(floorf(log2f(v)))))
        let mantissa = UInt16(((v / powf(2, Float(exponent))) - 1) * 1024 + 0.5) & 0x3FF
        return sign | UInt16((exponent + 15) << 10) | mantissa
    }

    @MainActor
    private static func runClip(named name: String,
                                positions: [CGFloat],
                                squareSize: CGFloat,
                                engine: BlendEngine,
                                service: OpticalFlowService,
                                ciContext: CIContext,
                                directory: URL,
                                report: inout String) throws {
        let width = 720, height = 480
        let frames = positions.compactMap {
            makeFrame(width: width, height: height,
                      squareX: $0, squareY: CGFloat(height) / 2 - squareSize / 2,
                      squareSize: squareSize)
        }
        guard frames.count == positions.count else {
            report += "\(name): FRAME SYNTHESIS FAILED\n"
            return
        }

        report += "=== \(name): \(frames.count) frames, step \(positions[1] - positions[0]) px at \(width) wide ===\n"

        let flows = service.flows(for: frames, using: ciContext)
        for (i, flow) in flows.enumerated() {
            if let flow {
                report += "pair \(i): maxMagnitude \(flow.maxMagnitude) px at flow width \(Int(flow.measuredWidth))"
                report += " (=\(flow.maxMagnitude * Float(width) / Float(flow.measuredWidth)) px at frame res)\n"
            } else {
                report += "pair \(i): FLOW FAILED (nil)\n"
            }
        }

        // Same pair, .high accuracy, for comparison.
        if frames.count >= 2, let highMag = highAccuracyMaxMagnitude(
            from: frames[0], to: frames[1], service: service, ciContext: ciContext) {
            report += "pair 0 at .high accuracy: maxMagnitude \(highMag) px at flow res\n"
        }

        // Where exactly does the service's path fail? Re-run pair 0 raw.
        if frames.count >= 2 {
            report += rawFlowDiagnosis(from: frames[0], to: frames[1], ciContext: ciContext)
        }

        let off = try engine.blend(frames: frames, bias: 0)
        try writePNG(off, to: directory.appendingPathComponent("\(name)-off.png"))

        let interpolation = BlendInterpolation(flows: flows, shakeDeltas: [])
        let on = try engine.blend(frames: frames, bias: 0, interpolation: interpolation)
        try writePNG(on, to: directory.appendingPathComponent("\(name)-on.png"))

        if let flow = flows.first ?? nil {
            let mid = try engine.renderIntermediate(between: frames[0], and: frames[1],
                                                    flow: flow, t: 0.5)
            try writePNG(mid, to: directory.appendingPathComponent("\(name)-mid.png"))
            report += "midpoint expected square centre x ≈ \((positions[0] + positions[1]) / 2 + squareSize / 2)\n"
        } else {
            report += "no flow for pair 0 — midpoint skipped\n"
        }
        report += "\n"
    }

    // MARK: - Raw failure diagnosis

    /// Replicates OpticalFlowService.flow step by step and reports which stage
    /// fails: the Vision perform, the missing observation, or the pixel-format
    /// guard in the Metal-compatible copy.
    private static func rawFlowDiagnosis(from earlier: CVPixelBuffer,
                                         to later: CVPixelBuffer,
                                         ciContext: CIContext) -> String {
        var out = "raw diagnosis (pair 0, .medium, 16Half requested):\n"
        let request = VNGenerateOpticalFlowRequest(targetedCVPixelBuffer: later)
        request.computationAccuracy = .medium
        request.outputPixelFormat = kCVPixelFormatType_TwoComponent16Half
        let handler = VNImageRequestHandler(cvPixelBuffer: earlier)
        do {
            try handler.perform([request])
            if let observation = request.results?.first {
                let format = CVPixelBufferGetPixelFormatType(observation.pixelBuffer)
                let fourCC = String(bytes: [24, 16, 8, 0].map {
                    UInt8((format >> $0) & 0xFF)
                }, encoding: .ascii) ?? "????"
                out += "  perform OK; observation format '\(fourCC)' (\(format)), "
                out += "\(CVPixelBufferGetWidth(observation.pixelBuffer))x\(CVPixelBufferGetHeight(observation.pixelBuffer))\n"
                out += "  16Half expected: \(kCVPixelFormatType_TwoComponent16Half), matches: \(format == kCVPixelFormatType_TwoComponent16Half)\n"
            } else {
                out += "  perform OK but results empty\n"
            }
        } catch {
            out += "  perform THREW: \(error)\n"
        }
        return out
    }

    // MARK: - .high accuracy probe

    /// Runs Vision directly at .high accuracy on one downsampled pair and
    /// returns the max flow magnitude, to compare against the service's .medium.
    private static func highAccuracyMaxMagnitude(from earlier: CVPixelBuffer,
                                                 to later: CVPixelBuffer,
                                                 service: OpticalFlowService,
                                                 ciContext: CIContext) -> Float? {
        func shrink(_ buffer: CVPixelBuffer) -> CVPixelBuffer {
            let width = CVPixelBufferGetWidth(buffer)
            let height = CVPixelBufferGetHeight(buffer)
            let scale = OpticalFlowService.flowLongEdge / CGFloat(max(width, height))
            guard scale < 1 else { return buffer }
            var out: CVPixelBuffer?
            let attrs: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: Int(kCVPixelFormatType_32BGRA),
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
            ]
            CVPixelBufferCreate(kCFAllocatorDefault, Int(CGFloat(width) * scale),
                                Int(CGFloat(height) * scale), kCVPixelFormatType_32BGRA,
                                attrs as CFDictionary, &out)
            guard let target = out else { return buffer }
            ciContext.render(CIImage(cvPixelBuffer: buffer)
                .transformed(by: CGAffineTransform(scaleX: scale, y: scale)), to: target)
            return target
        }

        let request = VNGenerateOpticalFlowRequest(targetedCVPixelBuffer: shrink(later))
        request.computationAccuracy = .high
        request.outputPixelFormat = kCVPixelFormatType_TwoComponent16Half
        let handler = VNImageRequestHandler(cvPixelBuffer: shrink(earlier))
        guard (try? handler.perform([request])) != nil,
              let observation = request.results?.first else { return nil }

        let buffer = observation.pixelBuffer
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let w = CVPixelBufferGetWidth(buffer)
        let h = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)

        var maxSquared: Float = 0
        for row in 0..<h {
            let halves = base.advanced(by: row * rowBytes)
                .bindMemory(to: UInt16.self, capacity: w * 2)
            for x in 0..<w {
                let dx = float(fromHalf: halves[x * 2])
                let dy = float(fromHalf: halves[x * 2 + 1])
                let squared = dx * dx + dy * dy
                if squared.isFinite, squared > maxSquared { maxSquared = squared }
            }
        }
        return maxSquared.squareRoot()
    }

    private static func float(fromHalf bits: UInt16) -> Float {
        let sign: Float = (bits & 0x8000) != 0 ? -1 : 1
        let exponent = Int((bits >> 10) & 0x1F)
        let mantissa = Float(bits & 0x3FF)
        switch exponent {
        case 0:     return sign * mantissa * powf(2, -24)
        case 0x1F:  return mantissa == 0 ? sign * .infinity : .nan
        default:    return sign * (1 + mantissa / 1024) * powf(2, Float(exponent - 15))
        }
    }

    // MARK: - Frame synthesis

    /// Light-gray frame with a static grid of dark blocks (texture anchors for
    /// the flow estimator) and one red square at `squareX`.
    private static func makeFrame(width: Int, height: Int,
                                  squareX: CGFloat, squareY: CGFloat,
                                  squareSize: CGFloat) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
        ]
        CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                            kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb)
        guard let buffer = pb else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer),
              let ctx = CGContext(data: base, width: width, height: height,
                                  bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                      | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }

        ctx.setFillColor(CGColor(red: 0.85, green: 0.85, blue: 0.85, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        ctx.setFillColor(CGColor(red: 0.2, green: 0.2, blue: 0.25, alpha: 1))
        for gx in stride(from: 30, to: width, by: 90) {
            for gy in stride(from: 30, to: height, by: 90) {
                ctx.fill(CGRect(x: gx, y: gy, width: 14, height: 14))
            }
        }

        ctx.setFillColor(CGColor(red: 0.9, green: 0.1, blue: 0.1, alpha: 1))
        ctx.fill(CGRect(x: squareX, y: squareY, width: squareSize, height: squareSize))
        return buffer
    }

    private static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let data = UIImage(cgImage: image).pngData() else {
            throw NSError(domain: "FlowSpike", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "PNG encode failed"])
        }
        try data.write(to: url)
    }
}

#endif
