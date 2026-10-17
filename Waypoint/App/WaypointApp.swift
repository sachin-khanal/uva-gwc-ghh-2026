//
// File:     Waypoint/App/WaypointApp.swift
// Owner:    D (App/Sync/Integration)
// Purpose:  App entry point. Creates the single shared `AppState` and shows `RootView`.
// Status:   DONE for scaffold. Rarely needs to change.
//
import SwiftUI

@main
struct WaypointApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appState)
        }
    }
}
