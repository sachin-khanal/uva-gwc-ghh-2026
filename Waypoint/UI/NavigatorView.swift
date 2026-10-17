//
// File:     Waypoint/UI/NavigatorView.swift
// Owner:    D (UI) with B (NavigationController)
// Purpose:  Navigator screen: pick a map and a destination, press Start. While navigating the
//           screen only shows status text - the blind user relies on audio and haptics. (A sighted
//           helper/judge escort can read the status.)
// Status:   SCAFFOLD. TODO(D): voice destination input (SFSpeechRecognizer, stretch goal),
//           one giant Start target, keep-screen-awake while navigating.
//
import SwiftUI
import WaypointCore

struct NavigatorView: View {
    @EnvironmentObject var app: AppState
    @StateObject private var nav = NavigationController()
    @State private var selectedMapId: UUID?
    @State private var isNavigating = false

    private var selectedMap: BuildingMap? { app.maps.first { $0.id == selectedMapId } ?? app.maps.first }

    var body: some View {
        Group {
            if isNavigating {
                navigatingBody
            } else {
                pickerBody
            }
        }
        .onDisappear { stopNavigation() }
    }

    private var pickerBody: some View {
        List {
            if app.maps.isEmpty {
                Text("No maps yet. Scan one in Volunteer mode or receive one via Share maps.")
            }
            Section("Map") {
                ForEach(app.maps) { map in
                    Button {
                        selectedMapId = map.id
                    } label: {
                        HStack {
                            Text(map.name)
                            Spacer()
                            if map.id == selectedMap?.id { Image(systemName: "checkmark") }
                        }
                    }
                }
            }
            if let map = selectedMap {
                Section("Go to...") {
                    ForEach(map.destinations) { dest in
                        Button(dest.label ?? "Unnamed") { startNavigation(map: map, destination: dest) }
                            .accessibilityLabel("Navigate to \(dest.label ?? "unnamed")")
                    }
                }
            }
        }
    }

    private var navigatingBody: some View {
        VStack(spacing: 20) {
            Text(nav.statusText).font(.title)
            Text(nav.instructionText).font(.title3).foregroundStyle(.secondary)
            if nav.obstacleLevel != .clear {
                Text(nav.obstacleLevel == .stop ? "STOP" : "Obstacle ahead")
                    .font(.largeTitle).bold().foregroundStyle(.red)
            }
            Button("Stop") { stopNavigation() }
                .buttonStyle(.borderedProminent).controlSize(.large)
        }
        .padding()
    }

    private func startNavigation(map: BuildingMap, destination: MapNode) {
        isNavigating = true
        UIApplication.shared.isIdleTimerDisabled = true // keep the screen on while walking
        nav.start(map: map, destination: destination, store: app.store)
    }

    private func stopNavigation() {
        guard isNavigating else { return }
        nav.stop()
        isNavigating = false
        UIApplication.shared.isIdleTimerDisabled = false
    }
}
