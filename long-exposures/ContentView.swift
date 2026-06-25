//
//  ContentView.swift
//  long-exposures
//
//  Phase 1 debug screen: pick a Live Photo, extract frames, dump PNGs to disk.
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
