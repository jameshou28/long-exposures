//
//  LivePhotoPicker.swift
//  long-exposures
//
//  Wraps PHPickerViewController so we get the picked asset's local identifier reliably.
//  SwiftUI's PhotosPicker does not return itemIdentifier without an explicit PHPhotoLibrary binding.
//

import SwiftUI
import PhotosUI

struct LivePhotoPicker: UIViewControllerRepresentable {

    var onPick: ([String]) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration(photoLibrary: .shared())
        config.filter = .livePhotos
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
        let onPick: ([String]) -> Void
        init(onPick: @escaping ([String]) -> Void) { self.onPick = onPick }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            let identifiers = results.compactMap { $0.assetIdentifier }
            onPick(identifiers)
        }
    }
}
