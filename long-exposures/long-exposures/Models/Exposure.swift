//
//  Exposure.swift
//  long-exposures
//
//  A saved long-exposure in the in-app library. The image lives as a
//  JPEG in the app's Documents/Exposures directory; this is its metadata sidecar.
//

import Foundation

struct Exposure: Identifiable, Codable, Hashable {
    let id: UUID
    let createdAt: Date
    let mode: String          // BlendMode raw label, e.g. "average"
    let frameCount: Int       // number of frames blended
    let imageFileName: String // file name within the Exposures directory

    init(id: UUID = UUID(), createdAt: Date = Date(), mode: String, frameCount: Int, imageFileName: String) {
        self.id = id
        self.createdAt = createdAt
        self.mode = mode
        self.frameCount = frameCount
        self.imageFileName = imageFileName
    }
}

extension BlendMode {
    var label: String {
        switch self {
        case .average: return "average"
        case .lighten: return "lighten"
        case .darken:  return "darken"
        }
    }
}
