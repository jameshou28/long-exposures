//
//  LibraryStore.swift
//  long-exposures
//
//  In-app library of saved long exposures (jpegs). 
//

import Foundation
import Observation
import UIKit

@Observable
@MainActor
final class LibraryStore {

    private(set) var exposures: [Exposure] = []

    private let directory: URL
    private let indexURL: URL

    init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        directory = documents.appendingPathComponent("Exposures", isDirectory: true)
        indexURL = directory.appendingPathComponent("index.json")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        load()
    }

    func imageURL(for exposure: Exposure) -> URL {
        directory.appendingPathComponent(exposure.imageFileName)
    }

    func image(for exposure: Exposure) -> UIImage? {
        UIImage(contentsOfFile: imageURL(for: exposure).path)
    }

    @discardableResult
    func add(image: CGImage, modeLabel: String, frameCount: Int) throws -> Exposure {
        let fileName = "\(UUID().uuidString).jpg"
        let url = directory.appendingPathComponent(fileName)
        guard let data = UIImage(cgImage: image).jpegData(compressionQuality: 0.95) else {
            throw NSError(domain: "LibraryStore", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Could not encode JPEG."])
        }
        try data.write(to: url)

        let exposure = Exposure(mode: modeLabel, frameCount: frameCount, imageFileName: fileName)
        exposures.insert(exposure, at: 0)
        try saveIndex()
        return exposure
    }

    func delete(_ exposure: Exposure) {
        try? FileManager.default.removeItem(at: imageURL(for: exposure))
        exposures.removeAll { $0.id == exposure.id }
        try? saveIndex()
    }

    private func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let decoded = try? JSONDecoder().decode([Exposure].self, from: data) else {
            exposures = []
            return
        }
        // drop any entries whose image file is missing (e.g. manual deletion).
        exposures = decoded.filter { FileManager.default.fileExists(atPath: imageURL(for: $0).path) }
    }

    private func saveIndex() throws {
        let data = try JSONEncoder().encode(exposures)
        try data.write(to: indexURL, options: .atomic)
    }
}
