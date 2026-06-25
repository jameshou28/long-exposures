//
//  ContentView.swift
//  long-exposures
//
//  Phase 1–2 debug screen: pick a Live Photo, extract frames, blend them.
//

import SwiftUI
import Photos

struct ContentView: View {

    @State private var frameStore = FrameStore()
    @State private var isPickerPresented = false
    @State private var statusMessage = "Pick a Live Photo to extract its frames."
    @State private var dumpDirectory: URL?
    @State private var isWorking = false
    @State private var authStatus: PHAuthorizationStatus = .notDetermined
    @State private var blendedImage: UIImage?

    private let importService = ImportService()

    var body: some View {
        VStack(spacing: 24) {
            Text("Long Exposures")
                .font(.title2.weight(.semibold))
            Text("Phase 2 — Blend Engine")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Text(statusMessage)
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal)

            if isWorking {
                ProgressView()
            }

            Button {
                Task { await beginPick() }
            } label: {
                Text("Pick Live Photo")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(.tint, in: RoundedRectangle(cornerRadius: 12))
                    .foregroundStyle(.white)
            }
            .disabled(isWorking)

            if !frameStore.fullResolutionFrames.isEmpty {
                VStack(spacing: 4) {
                    Text("Loaded \(frameStore.fullResolutionFrames.count) full-res frames")
                    Text("Preview frames: \(frameStore.previewFrames.count)")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)

                HStack(spacing: 12) {
                    blendButton("Average", mode: .average)
                    blendButton("Lighten", mode: .lighten)
                    blendButton("Darken", mode: .darken)
                }
                .disabled(isWorking)
            }

            if let blendedImage {
                Image(uiImage: blendedImage)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 280)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }

            if let dumpDirectory {
                Text("Output at:\n\(dumpDirectory.path)")
                    .font(.caption2)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(.horizontal)
            }

            Spacer()
        }
        .padding()
        .sheet(isPresented: $isPickerPresented) {
            LivePhotoPicker { identifiers in
                isPickerPresented = false
                print("[long-exposures] picker returned identifiers: \(identifiers)")
                guard let identifier = identifiers.first else {
                    statusMessage = "Picker returned with no asset identifier (was cancelled or no Live Photo selected)."
                    return
                }
                Task { await handlePickedAsset(identifier: identifier) }
            }
        }
    }

    private func blendButton(_ title: String, mode: BlendMode) -> some View {
        Button(title) {
            Task { await runBlend(mode: mode) }
        }
        .font(.subheadline.weight(.medium))
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
    }

    private func runBlend(mode: BlendMode) async {
        isWorking = true
        dumpDirectory = nil
        defer { isWorking = false }

        // Blend full-res frames; Phase 3 will switch interaction to preview-res.
        let frames = frameStore.fullResolutionFrames
        guard !frames.isEmpty else { return }

        statusMessage = "Blending \(frames.count) frames (\(mode))…"
        do {
            let engine = try BlendEngine()
            let start = Date()
            let cgImage = try engine.blend(frames: frames, mode: mode)
            let elapsed = Date().timeIntervalSince(start)
            blendedImage = UIImage(cgImage: cgImage)
            let url = try FrameDebugWriter.dumpPNG(cgImage, name: "blend-\(mode)")
            dumpDirectory = url
            statusMessage = "Blended \(frames.count) frames in \(String(format: "%.2f", elapsed))s (\(mode))."
            print("[long-exposures] blend (\(mode)) wrote:", url.path)
        } catch {
            statusMessage = "Blend failed: \(error.localizedDescription)"
            print("[long-exposures] blend error: \(error)")
        }
    }

    private func beginPick() async {
        let status = await ImportService.requestAuthorization()
        authStatus = status
        print("[long-exposures] photo auth status: \(status.rawValue)")
        guard status == .authorized || status == .limited else {
            statusMessage = "Photo library access denied. Enable it in Settings."
            return
        }
        statusMessage = "Opening picker…"
        isPickerPresented = true
    }

    private func handlePickedAsset(identifier: String) async {
        isWorking = true
        dumpDirectory = nil
        defer { isWorking = false }

        statusMessage = "Loading paired video…"
        do {
            let asset = try importService.asset(forLocalIdentifier: identifier)
            print("[long-exposures] resolved PHAsset, mediaSubtypes: \(asset.mediaSubtypes.rawValue)")
            let frames = try await importService.extractFrames(from: asset)
            statusMessage = "Decoded \(frames.count) frames. Building preview set…"
            frameStore.ingest(frames: frames)
            statusMessage = "Writing \(frames.count) PNGs to disk…"
            let directory = try FrameDebugWriter.dumpPNGs(frames)
            dumpDirectory = directory
            statusMessage = "Done. Extracted \(frames.count) frames."
            print("[long-exposures] Extracted PNG dump:", directory.path)
        } catch {
            statusMessage = "Failed: \(error.localizedDescription)"
            print("[long-exposures] error: \(error)")
        }
    }
}

#Preview {
    ContentView()
}
