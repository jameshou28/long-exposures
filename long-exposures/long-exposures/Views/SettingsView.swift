//
//  SettingsView.swift
//  long-exposures
//
//  App defaults — the blend mode and export resolution a new edit starts
//  with. Changes persist immediately via AppSettings.
//

import SwiftUI

struct SettingsView: View {

    @Bindable var settings: AppSettings
    /// Re-opens the first-launch intro.
    var onShowOnboarding: () -> Void = {}

    var body: some View {
        Form {
            Section {
                Picker("Blend mode", selection: $settings.defaultMode) {
                    ForEach(BlendMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                Picker("Export resolution", selection: $settings.defaultResolution) {
                    ForEach(ExportResolution.allCases, id: \.self) { resolution in
                        Text(resolution.displayName).tag(resolution)
                    }
                }
            } header: {
                Text("Defaults")
            } footer: {
                Text("New edits open with these. You can still change them per edit.")
            }

            Section {
                Button {
                    onShowOnboarding()
                } label: {
                    Label("How it works", systemImage: "questionmark.circle")
                }
            }

            Section("About") {
                LabeledContent("Processing", value: "On device")
                LabeledContent("Data collected", value: "None")
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
    }
}
