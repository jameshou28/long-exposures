//
//  long_exposuresApp.swift
//  long-exposures
//
//  Created by James Hou on 6/24/26.
//

import SwiftUI

@main
struct long_exposuresApp: App {
    init() {
        // Reclaim temp video files left behind by imports in earlier runs.
        ImportService.purgeTempVideos()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
