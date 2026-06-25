//
//  ImportService.swift
//  long-exposures
//
//  Phase 1: pulls frames out of a Live Photo (or any video) as BGRA pixel buffers.
//

import Foundation
import Photos
import AVFoundation
import CoreVideo

enum ImportError: LocalizedError {
    case authorizationDenied
    case assetNotFound
    case noPairedVideo
    case noVideoTrack
    case readerFailed(String)

    var errorDescription: String? {
        switch self {
        case .authorizationDenied: return "Photo library access was denied."
        case .assetNotFound: return "Could not resolve the picked asset."
        case .noPairedVideo: return "Selected item has no paired video resource."
        case .noVideoTrack: return "Video has no readable video track."
        case .readerFailed(let reason): return "Frame reader failed: \(reason)"
        }
    }
}

struct ImportService {

    static func requestAuthorization() async -> PHAuthorizationStatus {
        await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                continuation.resume(returning: status)
            }
        }
    }

    func asset(forLocalIdentifier identifier: String) throws -> PHAsset {
        let result = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil)
        guard let asset = result.firstObject else { throw ImportError.assetNotFound }
        return asset
    }

    /// Writes the paired video resource of a Live Photo asset to a temp file and returns its URL.
    func videoURL(for asset: PHAsset) async throws -> URL {
        let resources = PHAssetResource.assetResources(for: asset)
        let candidate = resources.first(where: { $0.type == .pairedVideo })
            ?? resources.first(where: { $0.type == .fullSizePairedVideo })
            ?? resources.first(where: { $0.type == .video })
            ?? resources.first(where: { $0.type == .fullSizeVideo })
        guard let videoResource = candidate else { throw ImportError.noPairedVideo }

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mov")

        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true

        return try await withCheckedThrowingContinuation { continuation in
            PHAssetResourceManager.default().writeData(for: videoResource, toFile: tempURL, options: options) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: tempURL)
                }
            }
        }
    }

    /// Decodes every frame of a video URL to BGRA CVPixelBuffers. Faster than AVAssetImageGenerator for a full sweep.
    func extractFrames(from url: URL) async throws -> [CVPixelBuffer] {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = tracks.first else { throw ImportError.noVideoTrack }

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
        ])
        // Copy so buffers we keep aren't reused by the reader's pool.
        output.alwaysCopiesSampleData = true
        reader.add(output)

        guard reader.startReading() else {
            throw ImportError.readerFailed(reader.error?.localizedDescription ?? "could not start")
        }

        var frames: [CVPixelBuffer] = []
        while let sample = output.copyNextSampleBuffer() {
            if let buffer = CMSampleBufferGetImageBuffer(sample) {
                frames.append(buffer)
            }
        }

        if reader.status == .failed {
            throw ImportError.readerFailed(reader.error?.localizedDescription ?? "reader failed")
        }

        return frames
    }

    /// Convenience: PHAsset → paired video URL → frames.
    func extractFrames(from asset: PHAsset) async throws -> [CVPixelBuffer] {
        let url = try await videoURL(for: asset)
        return try await extractFrames(from: url)
    }
}
