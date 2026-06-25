//
//  CapturePreview.swift
//  long-exposures
//
//  Phase 7: a thin SwiftUI wrapper around AVCaptureVideoPreviewLayer so the
//  capture screen can show the live camera feed.
//

import SwiftUI
import AVFoundation

struct CapturePreview: UIViewRepresentable {

    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        uiView.previewLayer.session = session
    }

    /// A UIView whose backing layer is the capture preview layer.
    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer {
            layer as! AVCaptureVideoPreviewLayer
        }
    }
}
