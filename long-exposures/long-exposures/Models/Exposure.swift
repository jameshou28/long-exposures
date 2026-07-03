//
//  Exposure.swift
//  long-exposures
//
//  A saved long-exposure (jpeg) in the in-app library
//

import Foundation

struct Exposure: Identifiable, Codable, Hashable {
    let id: UUID
    let createdAt: Date
    let mode: String // BlendMode raw label
    let frameCount: Int // num of frames blended
    let imageFileName: String // file name

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

    static func label(forBias bias: Float) -> String {
        let b = min(max(bias, -1), 1)
        if abs(b) < 0.05 { return "average" }
        let direction = b > 0 ? "lighten" : "darken"
        let percent = Int((abs(b) * 100).rounded())
        return percent >= 95 ? direction : "\(direction) \(percent)%"
    }
}