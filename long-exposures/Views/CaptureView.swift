//
//  CaptureView.swift
//  long-exposures
//
//  Phase 7: the in-app capture screen. Live preview with a record button; locks
//  exposure and white balance on record so frames stay consistent. On stop, the
//  captured frames are handed back to be ingested into the same FrameStore as an
//  imported clip.
//

import SwiftUI
import CoreVideo

struct CaptureView: View {

    /// Called with the captured BGRA frames when the user finishes recording.
    let onCaptured: ([CVPixelBuffer]) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var capture = CaptureService()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if capture.isConfigured {
                CapturePreview(session: capture.session)
                    .ignoresSafeArea()
            }

            VStack {
                topBar
                Spacer()
                if let error = capture.errorMessage {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .padding()
                        .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
                        .padding()
                }
                controls
            }
        }
        .task { await capture.configure() }
        .onDisappear { capture.stopSession() }
    }

    private var topBar: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .padding(10)
                    .background(.black.opacity(0.4), in: Circle())
            }
            .accessibilityLabel("Cancel capture")
            Spacer()
            if capture.state == .recording {
                Label("\(capture.capturedFrameCount)", systemImage: "record.circle")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.red.opacity(0.7), in: Capsule())
            }
        }
        .padding()
    }

    private var controls: some View {
        VStack(spacing: 12) {
            if capture.state == .idle {
                Text("Hold steady. Exposure locks when you start.")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.8))
            }
            recordButton
                .padding(.bottom, 32)
        }
    }

    private var recordButton: some View {
        Button {
            switch capture.state {
            case .idle:
                capture.startRecording()
            case .recording:
                Task {
                    let frames = await capture.stopRecording()
                    onCaptured(frames)
                    dismiss()
                }
            case .finished:
                break
            }
        } label: {
            ZStack {
                Circle()
                    .strokeBorder(.white, lineWidth: 4)
                    .frame(width: 76, height: 76)
                RoundedRectangle(cornerRadius: capture.state == .recording ? 6 : 30)
                    .fill(.red)
                    .frame(width: capture.state == .recording ? 32 : 60,
                           height: capture.state == .recording ? 32 : 60)
                    .animation(.easeInOut(duration: 0.2), value: capture.state)
            }
        }
        .disabled(!capture.isConfigured || capture.state == .finished)
        .accessibilityLabel(capture.state == .recording ? "Stop recording" : "Start recording")
    }
}
