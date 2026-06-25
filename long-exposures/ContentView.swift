//
//  ContentView.swift
//  long-exposures
//
//  Phase 3: import a Live Photo, then drive the interactive editor.
//

import SwiftUI
import Photos

struct ContentView: View {

    @State private var frameStore = FrameStore()
    @State private var library = LibraryStore()
    @State private var editorModel: EditorViewModel?
    @State private var isPickerPresented = false
    @State private var isLibraryPresented = false
    @State private var statusMessage = "Pick a Live Photo to begin."
    @State private var isWorking = false

    private let importService = ImportService()

    var body: some View {
        NavigationStack {
            Group {
                if let editorModel {
                    EditorView(model: editorModel)
                } else {
                    landing
                }
            }
            .navigationTitle("Long Exposures")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        isLibraryPresented = true
                    } label: {
                        Image(systemName: "photo.stack")
                    }
                }
                if editorModel != nil {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("New") { Task { await beginPick() } }
                            .disabled(isWorking)
                    }
                }
            }
        }
        .sheet(isPresented: $isPickerPresented) {
            LivePhotoPicker { identifiers in
                isPickerPresented = false
                guard let identifier = identifiers.first else {
                    statusMessage = "No Live Photo selected."
                    return
                }
                Task { await handlePickedAsset(identifier: identifier) }
            }
        }
        .sheet(isPresented: $isLibraryPresented) {
            NavigationStack {
                LibraryView(library: library)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Done") { isLibraryPresented = false }
                        }
                    }
            }
        }
    }

    private var landing: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "camera.aperture")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            Text(statusMessage)
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
            if isWorking { ProgressView() }
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
            .padding(.horizontal, 40)
            Spacer()
        }
        .padding()
    }

    private func beginPick() async {
        let status = await ImportService.requestAuthorization()
        guard status == .authorized || status == .limited else {
            statusMessage = "Photo library access denied. Enable it in Settings."
            editorModel = nil
            return
        }
        statusMessage = "Opening picker…"
        isPickerPresented = true
    }

    private func handlePickedAsset(identifier: String) async {
        isWorking = true
        defer { isWorking = false }

        statusMessage = "Loading paired video…"
        do {
            let asset = try importService.asset(forLocalIdentifier: identifier)
            let frames = try await importService.extractFrames(from: asset)
            guard !frames.isEmpty else {
                statusMessage = "No frames could be decoded from that item."
                return
            }
            frameStore.ingest(frames: frames)

            let engine = try BlendEngine()
            let model = EditorViewModel(frameStore: frameStore, engine: engine, library: library)
            model.load()
            editorModel = model
        } catch {
            statusMessage = "Failed: \(error.localizedDescription)"
            editorModel = nil
            print("[long-exposures] error: \(error)")
        }
    }
}

#Preview {
    ContentView()
}
