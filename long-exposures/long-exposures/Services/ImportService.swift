//
//  ImportService.swift
//  long-exposures
//
//  Pulls frames out of a live photo (or any video) as bgra pixel buffers.
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

    /// writes the paired video resource of a live photo to a temp file and returns its URL.
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

    /// max frames to include - really only effects the vids not live photos
    static let maxFrames = 167

    func extractFrames(from url: URL) async throws -> [CVPixelBuffer] {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = tracks.first else { throw ImportError.noVideoTrack }

        // estimate the total frame count
        let stride = await sampleStride(for: asset, track: track)

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
        ])
        // copy so buffers kept aren't reused by the reader's pool
        output.alwaysCopiesSampleData = true
        reader.add(output)

        guard reader.startReading() else {
            throw ImportError.readerFailed(reader.error?.localizedDescription ?? "could not start")
        }

        var frames: [CVPixelBuffer] = []
        var index = 0
        while let sample = output.copyNextSampleBuffer() {
            defer { index += 1 }
            guard index % stride == 0, frames.count < Self.maxFrames else { continue }
            if let buffer = CMSampleBufferGetImageBuffer(sample) {
                frames.append(buffer)
            }
        }

        if reader.status == .failed {
            throw ImportError.readerFailed(reader.error?.localizedDescription ?? "reader failed")
        }

        return frames
    }

    /// stride that keeps a clip at or under `maxFrames`, sampled evenly
    private func sampleStride(for asset: AVAsset, track: AVAssetTrack) async -> Int {
        guard let duration = try? await asset.load(.duration),
              let frameRate = try? await track.load(.nominalFrameRate),
              frameRate > 0, duration.seconds.isFinite, duration.seconds > 0 else {
            return 1
        }
        let estimatedTotal = Int((duration.seconds * Double(frameRate)).rounded())
        guard estimatedTotal > Self.maxFrames else { return 1 }
        return Int((Double(estimatedTotal) / Double(Self.maxFrames)).rounded(.up))
    }

    func extractFrames(from asset: PHAsset) async throws -> [CVPixelBuffer] {
        let url = try await videoURL(for: asset)
        defer { Self.removeTempFile(url) }
        return try await extractFrames(from: url)
    }

    /// rm a file from temp directory
    static func removeTempFile(_ url: URL) {
        let tempDir = FileManager.default.temporaryDirectory.standardizedFileURL.path
        guard url.standardizedFileURL.path.hasPrefix(tempDir) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// cleanup of leftover temp video files from earlier runs
    static func purgeTempVideos() {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory
        let videoExtensions: Set<String> = ["mov", "mp4", "m4v"]
        guard let contents = try? fm.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil) else { return }
        for url in contents where videoExtensions.contains(url.pathExtension.lowercased()) {
            try? fm.removeItem(at: url)
        }
    }
}
