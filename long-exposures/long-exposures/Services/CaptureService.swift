//
//  CaptureService.swift
//  long-exposures
//
//  Phase 7: in-app capture with locked exposure and white balance. Locked capture
//  produces consistent frames, which sidesteps the exposure-flicker problem
//  normalization solves for imported clips.
//
//  Flow:
//    1. Configure an AVCaptureSession with the back camera + a BGRA video data output.
//    2. Show the live feed (CapturePreview).
//    3. On record: lock exposure (custom mode, current duration/ISO) and white
//       balance, then collect every frame the data output delivers.
//    4. On stop: hand the collected BGRA buffers to the same FrameStore the
//       importer feeds. The rest of the pipeline is unchanged.
//
//  Threading: AVCaptureSession and its objects aren't Sendable and must be touched
//  on one serial queue. `SessionController` confines all of that to `sessionQueue`;
//  `CaptureService` is the @MainActor, @Observable face that drives the SwiftUI view.
//

import Foundation
import AVFoundation
import CoreVideo

enum CaptureError: LocalizedError {
    case authorizationDenied
    case noCamera
    case configurationFailed

    var errorDescription: String? {
        switch self {
        case .authorizationDenied: return "Camera access was denied. Enable it in Settings."
        case .noCamera: return "No usable camera was found on this device."
        case .configurationFailed: return "Could not configure the camera session."
        }
    }
}

@Observable
@MainActor
final class CaptureService {

    enum State {
        case idle        // configured, previewing, not recording
        case recording
        case finished
    }

    private(set) var state: State = .idle
    private(set) var isConfigured = false
    private(set) var capturedFrameCount = 0
    var errorMessage: String?

    @ObservationIgnored private let controller = SessionController()

    /// The session the preview layer renders. Exposed for `CapturePreview`.
    var session: AVCaptureSession { controller.session }

    static func requestAuthorization() async -> AVAuthorizationStatus {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        if status == .notDetermined {
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            return granted ? .authorized : .denied
        }
        return status
    }

    /// Builds the session and starts previewing. Idempotent.
    func configure() async {
        guard !isConfigured else { return }
        let status = await Self.requestAuthorization()
        guard status == .authorized else {
            errorMessage = CaptureError.authorizationDenied.errorDescription
            return
        }

        do {
            try await controller.configure()
            isConfigured = true
            controller.startSession()
        } catch let error as CaptureError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func stopSession() {
        controller.stopSession()
    }

    // MARK: - Recording

    /// Locks exposure + white balance, then starts collecting frames.
    func startRecording() {
        guard state == .idle, isConfigured else { return }
        controller.startRecording()
        capturedFrameCount = 0
        state = .recording
        pollFrameCount()
    }

    /// Stops collecting and returns the captured BGRA frames.
    func stopRecording() async -> [CVPixelBuffer] {
        guard state == .recording else { return [] }
        let frames = await controller.stopRecording()
        capturedFrameCount = frames.count
        state = .finished
        return frames
    }

    /// Mirror the collector's running count to the observable property while recording.
    private func pollFrameCount() {
        guard state == .recording else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.capturedFrameCount = await self.controller.frameCount()
            try? await Task.sleep(for: .milliseconds(100))
            self.pollFrameCount()
        }
    }
}

/// Owns the AVCaptureSession and all its non-Sendable objects, confining every
/// access to a single serial queue. `@unchecked Sendable` because that queue
/// confinement is the safety guarantee, not the type system.
private final class SessionController: @unchecked Sendable {

    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "co.jameshou.long-exposures.capture.session")
    private let output = AVCaptureVideoDataOutput()
    private let collector = FrameCollector()
    private var device: AVCaptureDevice?

    func configure() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                do {
                    try buildSession()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func buildSession() throws {
        session.beginConfiguration()
        session.sessionPreset = .high

        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
                ?? AVCaptureDevice.default(for: .video) else {
            session.commitConfiguration()
            throw CaptureError.noCamera
        }

        guard let input = try? AVCaptureDeviceInput(device: camera), session.canAddInput(input) else {
            session.commitConfiguration()
            throw CaptureError.configurationFailed
        }
        session.addInput(input)

        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)]
        output.alwaysDiscardsLateVideoFrames = false
        output.setSampleBufferDelegate(collector, queue: queue)
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            throw CaptureError.configurationFailed
        }
        session.addOutput(output)

        session.commitConfiguration()
        device = camera
    }

    func startSession() {
        queue.async { [session] in
            if !session.isRunning { session.startRunning() }
        }
    }

    func stopSession() {
        queue.async { [session] in
            if session.isRunning { session.stopRunning() }
        }
    }

    func startRecording() {
        queue.async { [self] in
            lockExposureAndWhiteBalance()
            collector.start()
        }
    }

    func stopRecording() async -> [CVPixelBuffer] {
        await withCheckedContinuation { (continuation: CheckedContinuation<[CVPixelBuffer], Never>) in
            queue.async { [collector] in
                continuation.resume(returning: collector.stop())
            }
        }
    }

    func frameCount() async -> Int {
        await withCheckedContinuation { (continuation: CheckedContinuation<Int, Never>) in
            queue.async { [collector] in
                continuation.resume(returning: collector.count)
            }
        }
    }

    /// Pins shutter/ISO and white balance so every captured frame matches.
    private func lockExposureAndWhiteBalance() {
        guard let device, (try? device.lockForConfiguration()) != nil else { return }
        if device.isExposureModeSupported(.custom) {
            device.setExposureModeCustom(duration: device.exposureDuration, iso: device.iso, completionHandler: nil)
        } else if device.isExposureModeSupported(.locked) {
            device.exposureMode = .locked
        }
        if device.isWhiteBalanceModeSupported(.locked) {
            device.whiteBalanceMode = .locked
        }
        device.unlockForConfiguration()
    }
}

/// Collects BGRA frames on the session queue. Buffers are copied out of the
/// output's reuse pool so they stay valid after the delegate returns. All access
/// is serialized on that queue, so no internal locking is needed.
private final class FrameCollector: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {

    private var isCollecting = false
    private var frames: [CVPixelBuffer] = []

    var count: Int { frames.count }

    func start() {
        frames.removeAll(keepingCapacity: true)
        isCollecting = true
    }

    func stop() -> [CVPixelBuffer] {
        isCollecting = false
        let result = frames
        frames = []
        return result
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard isCollecting, let source = CMSampleBufferGetImageBuffer(sampleBuffer),
              let copy = source.deepCopyBGRA() else { return }
        frames.append(copy)
    }
}

private extension CVPixelBuffer {
    /// Copies a BGRA pixel buffer so it survives past the data output's reuse pool.
    func deepCopyBGRA() -> CVPixelBuffer? {
        let width = CVPixelBufferGetWidth(self)
        let height = CVPixelBufferGetHeight(self)
        var copy: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
        ]
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                  kCVPixelFormatType_32BGRA, attrs as CFDictionary, &copy) == kCVReturnSuccess,
              let dst = copy else { return nil }

        CVPixelBufferLockBaseAddress(self, .readOnly)
        CVPixelBufferLockBaseAddress(dst, [])
        defer {
            CVPixelBufferUnlockBaseAddress(dst, [])
            CVPixelBufferUnlockBaseAddress(self, .readOnly)
        }
        guard let srcBase = CVPixelBufferGetBaseAddress(self),
              let dstBase = CVPixelBufferGetBaseAddress(dst) else { return nil }
        let srcRow = CVPixelBufferGetBytesPerRow(self)
        let dstRow = CVPixelBufferGetBytesPerRow(dst)
        if srcRow == dstRow {
            memcpy(dstBase, srcBase, srcRow * height)
        } else {
            let rowBytes = min(srcRow, dstRow)
            for y in 0..<height {
                memcpy(dstBase + y * dstRow, srcBase + y * srcRow, rowBytes)
            }
        }
        return dst
    }
}
