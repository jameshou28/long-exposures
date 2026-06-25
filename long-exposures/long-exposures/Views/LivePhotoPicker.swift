//
//  LivePhotoPicker.swift
//  long-exposures
//
//  Wraps PHPickerViewController to pick a Live Photo *or* a video. Live Photos
//  come back as a local identifier (resolved to the paired video via PhotoKit);
//  videos come back as a copied file URL loaded straight from the item provider.
//

import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

/// What the picker handed back. The import path resolves each to frames.
enum PickedItem {
    case livePhoto(identifier: String)
    case video(url: URL)
}

struct LivePhotoPicker: UIViewControllerRepresentable {

    var onPick: (PickedItem?) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration(photoLibrary: .shared())
        // Live Photos or videos. `.any(of:)` keeps both kinds selectable.
        config.filter = .any(of: [.livePhotos, .videos])
        config.selectionLimit = 1
        config.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick)
    }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onPick: (PickedItem?) -> Void
        init(onPick: @escaping (PickedItem?) -> Void) { self.onPick = onPick }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            guard let result = results.first else { return onPick(nil) }

            // A video item provides a movie file; a Live Photo gives an asset id.
            if result.itemProvider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
                loadVideo(from: result.itemProvider)
            } else if let identifier = result.assetIdentifier {
                onPick(.livePhoto(identifier: identifier))
            } else {
                onPick(nil)
            }
        }

        /// Copies the picked video to a temp URL we own (the provider's file is
        /// only valid inside the completion handler).
        private func loadVideo(from provider: NSItemProvider) {
            provider.loadFileRepresentation(forTypeIdentifier: UTType.movie.identifier) { [onPick] url, error in
                guard let url, error == nil else {
                    DispatchQueue.main.async { onPick(nil) }
                    return
                }
                let dest = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
                    .appendingPathExtension(url.pathExtension.isEmpty ? "mov" : url.pathExtension)
                do {
                    try FileManager.default.copyItem(at: url, to: dest)
                    DispatchQueue.main.async { onPick(.video(url: dest)) }
                } catch {
                    DispatchQueue.main.async { onPick(nil) }
                }
            }
        }
    }
}
