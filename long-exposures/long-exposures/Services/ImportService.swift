//
//  ImportService.swift
//  long-exposures
//
//  Pulls frames out of a Live Photo (or any video) as BGRA pixel buffers.
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

    /// Most frames we keep from one clip. A Live Photo's paired video is well under
    /// this; long regular videos are sampled down so memory and the timeline stay
    /// bounded. Every kept frame is held full-res, so this is a real ceiling.
    static let maxFrames = 167

    /// Decodes a video URL to BGRA CVPixelBuffers, evenly sampling down to
    /// `maxFrames` for long clips. Faster than AVAssetImageGenerator for a sweep.
    func extractFrames(from url: URL) async throws -> [CVPixelBuffer] {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = tracks.first else { throw ImportError.noVideoTrack }

        // Estimate the total frame count to pick a sampling stride. We don't know
        // the exact count up front, so estimate from duration × frame rate and keep
        // every Nth frame. A short clip gets stride 1 (every frame).
        let stride = await sampleStride(for: asset, track: track)

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
        var index = 0
        while let sample = output.copyNextSampleBuffer() {
            defer { index += 1 }
            // Keep every `stride`-th frame; cap total in case the estimate was low.
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

    /// Stride that keeps a clip at or under `maxFrames`, sampled evenly. Returns 1
    /// (keep every frame) for short clips or when the count can't be estimated.
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

    /// Convenience: PHAsset → paired video URL → frames. Deletes the temp video
    /// it wrote once decoding finishes (success or failure) so it doesn't linger.
    func extractFrames(from asset: PHAsset) async throws -> [CVPixelBuffer] {
        let url = try await videoURL(for: asset)
        defer { Self.removeTempFile(url) }
        return try await extractFrames(from: url)
    }

    /// Removes a file we wrote into the temp directory. No-op for anything outside it.
    static func removeTempFile(_ url: URL) {
        let tempDir = FileManager.default.temporaryDirectory.standardizedFileURL.path
        guard url.standardizedFileURL.path.hasPrefix(tempDir) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// One-shot cleanup of leftover temp video files from earlier runs (e.g. an
    /// import that crashed before its `defer` ran). Safe to call at launch.
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
