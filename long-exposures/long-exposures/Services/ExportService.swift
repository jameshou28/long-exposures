//
//  ExportService.swift
//  long-exposures
//
//  Renders the selected range at full resolution and saves it. Two
//  destinations: the in-app library (always) and the system Photos library
//  (on request). Full-res blend bypasses the preview cache.
//

import Foundation
import CoreVideo
import CoreImage
import Photos
import UIKit

enum ExportResolution: String, Hashable, CaseIterable {
    case full // native frame resolution
    case standard // long edge capped for smaller files / faster save

    var longEdgeCap: CGFloat? {
        switch self {
        case .full: return nil
        case .standard: return 2048
        }
    }
}

struct ExportService {

    let engine: BlendEngine

    /// Blends the selected range of full-res frames into one image.
    /// Bypasses the engine's range cache (which holds preview-res results).
    /// `interpolation`, when present, must be indexed like `frames`; it is
    /// sliced alongside them.
    func renderFullResolution(frames: [CVPixelBuffer], range: ClosedRange<Int>, bias: Float,
                              resolution: ExportResolution,
                              interpolation: BlendInterpolation? = nil) throws -> CGImage {
        let lower = max(0, range.lowerBound)
        let upper = min(frames.count - 1, range.upperBound)
        guard lower <= upper else { throw BlendError.noFrames }

        let cgImage = try engine.blend(frames: Array(frames[lower...upper]), bias: bias,
                                       interpolation: interpolation?.sliced(to: lower...upper))
        guard let cap = resolution.longEdgeCap else { return cgImage }
        return downscale(cgImage, longEdgeCap: cap)
    }

    private func downscale(_ image: CGImage, longEdgeCap: CGFloat) -> CGImage {
        let longEdge = CGFloat(max(image.width, image.height))
        guard longEdge > longEdgeCap else { return image }
        let scale = longEdgeCap / longEdge
        let ci = CIImage(cgImage: image).transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let context = CIContext()
        return context.createCGImage(ci, from: ci.extent) ?? image
    }

    /// Saves an image to the system Photos library. Requests add authorization if needed.
    static func saveToPhotos(_ image: CGImage) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw ImportError.authorizationDenied
        }
        let uiImage = UIImage(cgImage: image)
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.creationRequestForAsset(from: uiImage)
        }
    }
}
