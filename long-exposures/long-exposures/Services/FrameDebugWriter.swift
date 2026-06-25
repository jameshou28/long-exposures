//
//  FrameDebugWriter.swift
//  long-exposures
//
//  Phase 1 debug helper: writes every extracted frame as a PNG to a temp subdirectory.
//  Used to confirm decode is producing what we expect.
//

import Foundation
import CoreImage
import CoreVideo
import UIKit

enum FrameDebugWriter {

    /// Writes every frame as a PNG into a fresh subdirectory of the temp directory.
    /// Returns the directory URL so the caller can log or share it.
    @discardableResult
    static func dumpPNGs(_ frames: [CVPixelBuffer]) throws -> URL {
        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("frames-\(timestamp)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let context = CIContext()

        for (index, buffer) in frames.enumerated() {
            let ci = CIImage(cvPixelBuffer: buffer)
            guard let cg = context.createCGImage(ci, from: ci.extent) else { continue }
            guard let data = UIImage(cgImage: cg).pngData() else { continue }
            let url = directory.appendingPathComponent(String(format: "frame-%04d.png", index))
            try data.write(to: url)
        }

        return directory
    }

    /// Writes a single blended CGImage to a temp PNG and returns its URL.
    @discardableResult
    static func dumpPNG(_ image: CGImage, name: String = "blend") throws -> URL {
        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(timestamp).png")
        guard let data = UIImage(cgImage: image).pngData() else {
            throw NSError(domain: "FrameDebugWriter", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "PNG encode failed"])
        }
        try data.write(to: url)
        return url
    }
}
