//
//  AppSettings.swift
//  long-exposures
//
//  Phase 8: user defaults for the editor — the blend mode and export resolution
//  a new edit starts with. Persisted in UserDefaults; read once when an editor is
//  created so a fresh import lands on the user's preferred settings.
//

import Foundation
import Observation

@Observable
@MainActor
final class AppSettings {

    private enum Key {
        static let defaultMode = "settings.defaultBlendMode"
        static let defaultResolution = "settings.defaultExportResolution"
    }

    private let defaults: UserDefaults

    var defaultMode: BlendMode {
        didSet { defaults.set(defaultMode.rawValue, forKey: Key.defaultMode) }
    }
    var defaultResolution: ExportResolution {
        didSet { defaults.set(defaultResolution.rawValue, forKey: Key.defaultResolution) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.defaultMode = defaults.string(forKey: Key.defaultMode)
            .flatMap(BlendMode.init(rawValue:)) ?? .average
        self.defaultResolution = defaults.string(forKey: Key.defaultResolution)
            .flatMap(ExportResolution.init(rawValue:)) ?? .full
    }
}

extension BlendMode {
    /// Title-case name for display in pickers and lists.
    var displayName: String {
        rawValue.prefix(1).uppercased() + rawValue.dropFirst()
    }
}

extension ExportResolution {
    var displayName: String {
        switch self {
        case .full: return "Full"
        case .standard: return "Standard"
        }
    }
}
