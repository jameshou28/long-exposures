//
//  ContentView.swift
//  long-exposures
//
//  Phase 1 debug screen: pick a Live Photo, extract frames, dump PNGs to disk.
//

import SwiftUI
import PhotosUI
import Photos

struct ContentView: View {

    @State private var frameStore = FrameStore()
    @State private var pickedItem: PhotosPickerItem?
    @State private var statusMessage = "Pick a Live Photo to extract its frames."
    @State private var dumpDirectory: URL?
    @State private var isWorking = false
    @State private var authStatus: PHAuthorizationStatus = .notDetermined

    private let importService = ImportService()

    var body: some View {
        VStack(spacing: 24) {
            Text("Long Exposures")
                .font(.title2.weight(.semibold))
            Text("Phase 1 — Frame Extraction")
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

            PhotosPicker(selection: $pickedItem, matching: .livePhotos) {
                Text("Pick Live Photo")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(.tint, in: RoundedRectangle(cornerRadius: 12))
                    .foregroundStyle(.white)
            }
            .disabled(isWorking || !canPick)

            if !frameStore.fullResolutionFrames.isEmpty {
                VStack(spacing: 4) {
                    Text("Loaded \(frameStore.fullResolutionFrames.count) full-res frames")
                    Text("Preview frames: \(frameStore.previewFrames.count)")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }

            if let dumpDirectory {
                Text("PNGs at:\n\(dumpDirectory.path)")
                    .font(.caption2)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(.horizontal)
            }

            Spacer()
        }
        .padding()
        .task {
            authStatus = await ImportService.requestAuthorization()
            if !canPick {
                statusMessage = "Photo library access denied. Enable it in Settings."
            }
        }
        .onChange(of: pickedItem) { _, newItem in
            guard let newItem else { return }
            Task { await handlePicked(item: newItem) }
        }
    }

    private var canPick: Bool {
        authStatus == .authorized || authStatus == .limited
    }

    private func handlePicked(item: PhotosPickerItem) async {
        isWorking = true
        dumpDirectory = nil
        defer { isWorking = false }

        guard let identifier = item.itemIdentifier else {
            statusMessage = "Picked item has no asset identifier."
            return
        }

        statusMessage = "Loading paired video…"
        do {
            let asset = try importService.asset(forLocalIdentifier: identifier)
            let frames = try await importService.extractFrames(from: asset)
            statusMessage = "Decoded \(frames.count) frames. Building preview set…"
            frameStore.ingest(frames: frames)
            statusMessage = "Writing \(frames.count) PNGs to disk…"
            let directory = try FrameDebugWriter.dumpPNGs(frames)
            dumpDirectory = directory
            statusMessage = "Done."
            print("[long-exposures] Extracted PNG dump:", directory.path)
        } catch {
            statusMessage = "Failed: \(error.localizedDescription)"
        }
    }
}

#Preview {
    ContentView()
}
