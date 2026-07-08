//
//  ContentView.swift
//  long-exposures
//
//  import a Live Photo or video, then drive the interactive editor.
//

import SwiftUI
import Photos
import CoreVideo
import AVFoundation

struct ContentView: View {

    @State private var frameStore = FrameStore()
    @State private var library = LibraryStore()
    @State private var settings = AppSettings()
    @State private var editorModel: EditorViewModel?
    @State private var isPickerPresented = false
    @State private var isLibraryPresented = false
    @State private var isCapturePresented = false
    @State private var isSettingsPresented = false
    @State private var isOnboardingPresented = false
    @State private var primingFor: PermissionPriming.Kind?
    @State private var statusMessage = "Pick a Live Photo or video, or capture one to begin."
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
                    .accessibilityLabel("Library")
                }
                if editorModel == nil {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            isSettingsPresented = true
                        } label: {
                            Image(systemName: "gearshape")
                        }
                        .accessibilityLabel("Settings")
                    }
                } else {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("New") { returnToLanding() }
                            .disabled(isWorking)
                    }
                }
            }
        }
        .sheet(isPresented: $isPickerPresented) {
            LivePhotoPicker { item in
                isPickerPresented = false
                guard let item else {
                    statusMessage = "Nothing selected."
                    return
                }
                Task { await handlePicked(item) }
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
        .fullScreenCover(isPresented: $isCapturePresented) {
            CaptureView { frames in
                Task { await handleCapturedFrames(frames) }
            }
        }
        .sheet(isPresented: $isSettingsPresented) {
            NavigationStack {
                SettingsView(settings: settings) {
                    isSettingsPresented = false
                    isOnboardingPresented = true
                }
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { isSettingsPresented = false }
                    }
                }
            }
        }
        .sheet(item: $primingFor) { kind in
            PermissionPriming(kind: kind) {
                primingFor = nil
                Task { await proceedAfterPriming(kind) }
            } onCancel: {
                primingFor = nil
            }
        }
        .fullScreenCover(isPresented: $isOnboardingPresented) {
            OnboardingView {
                settings.hasSeenOnboarding = true
                isOnboardingPresented = false
            }
        }
        .onAppear {
            if !settings.hasSeenOnboarding {
                isOnboardingPresented = true
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
            VStack(spacing: 12) {
                Button {
                    Task { await beginPick() }
                } label: {
                    Text("Pick Live Photo or Video")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(.tint, in: RoundedRectangle(cornerRadius: 12))
                        .foregroundStyle(.white)
                }
                Button {
                    Task { await beginCapture() }
                } label: {
                    Label("Capture", systemImage: "camera")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(.tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .disabled(isWorking)
            .padding(.horizontal, 40)
            Spacer()
        }
        .padding()
    }

    private func returnToLanding() {
        editorModel = nil
        frameStore.clear()
        statusMessage = "Pick a Live Photo or video, or capture one to begin"
    }

    private func beginPick() async {
        if PHPhotoLibrary.authorizationStatus(for: .readWrite) == .notDetermined {
            primingFor = .photos
            return
        }
        await requestAndPick()
    }

    private func beginCapture() async {
        if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
            primingFor = .camera
            return
        }
        await requestAndCapture()
    }

    private func proceedAfterPriming(_ kind: PermissionPriming.Kind) async {
        switch kind {
        case .photos: await requestAndPick()
        case .camera: await requestAndCapture()
        }
    }

    private func requestAndPick() async {
        let status = await ImportService.requestAuthorization()
        guard status == .authorized || status == .limited else {
            statusMessage = "Photo library access denied. Enable it in Settings."
            editorModel = nil
            return
        }
        statusMessage = "Opening picker…"
        isPickerPresented = true
    }

    private func requestAndCapture() async {
        let status = await CaptureService.requestAuthorization()
        guard status == .authorized else {
            statusMessage = "Camera access denied. Enable it in Settings."
            return
        }
        isCapturePresented = true
    }

    private func handleCapturedFrames(_ frames: [CVPixelBuffer]) async {
        isWorking = true
        defer { isWorking = false }
        guard !frames.isEmpty else {
            statusMessage = "No frames were captured. Try recording for a moment longer."
            return
        }
        do {
            frameStore.ingest(frames: frames)
            editorModel = try makeEditor()
        } catch {
            statusMessage = "Failed: \(error.localizedDescription)"
            editorModel = nil
        }
    }

    private func makeEditor() throws -> EditorViewModel {
        let engine = try BlendEngine()
        let model = EditorViewModel(frameStore: frameStore, engine: engine, library: library, settings: settings)
        model.load()
        return model
    }

    private func handlePicked(_ item: PickedItem) async {
        isWorking = true
        defer { isWorking = false }

        statusMessage = "Decoding frames…"
        do {
            let frames: [CVPixelBuffer]
            switch item {
            case .livePhoto(let identifier):
                let asset = try importService.asset(forLocalIdentifier: identifier)
                frames = try await importService.extractFrames(from: asset)
            case .video(let url):
                defer { ImportService.removeTempFile(url) }
                frames = try await importService.extractFrames(from: url)
            }
            guard !frames.isEmpty else {
                statusMessage = "No frames could be decoded from that item."
                return
            }
            frameStore.ingest(frames: frames)
            editorModel = try makeEditor()
        } catch {
            statusMessage = "Failed: \(error.localizedDescription)"
            editorModel = nil
        }
    }
}

#Preview {
    ContentView()
}
