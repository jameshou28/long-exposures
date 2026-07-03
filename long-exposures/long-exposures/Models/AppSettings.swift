//
//  AppSettings.swift
//  long-exposures
//
//  user defaults for the editor
//

import Foundation
import Observation

@Observable
@MainActor
final class AppSettings {

    private enum Key {
        static let defaultMode = "settings.defaultBlendMode"
        static let defaultResolution = "settings.defaultExportResolution"
        static let hasSeenOnboarding = "settings.hasSeenOnboarding"
    }

    private let defaults: UserDefaults

    var defaultMode: BlendMode {
        didSet { defaults.set(defaultMode.rawValue, forKey: Key.defaultMode) }
    }
    var defaultResolution: ExportResolution {
        didSet { defaults.set(defaultResolution.rawValue, forKey: Key.defaultResolution) }
    }

    /// false until the user finishes (or skips) the first-launch intro.
    var hasSeenOnboarding: Bool {
        didSet { defaults.set(hasSeenOnboarding, forKey: Key.hasSeenOnboarding) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.defaultMode = defaults.string(forKey: Key.defaultMode)
            .flatMap(BlendMode.init(rawValue:)) ?? .average
        self.defaultResolution = defaults.string(forKey: Key.defaultResolution)
            .flatMap(ExportResolution.init(rawValue:)) ?? .full
        self.hasSeenOnboarding = defaults.bool(forKey: Key.hasSeenOnboarding)
    }
}

extension BlendMode {
    /// title-case name for display in pickers and lists.
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
