//
// File:     Waypoint/UI/Navigator/BuildingPickerView.swift
// Owner:    U3 (UI flows)
// Purpose:  N1 "Choose a building". Skipped automatically when the phone has exactly one map (NavigateFlow).
//           88 pt rows, one VoiceOver element each, and a large Exit at the bottom.
// Status:   SCAFFOLD.
//
import SwiftUI
import WaypointCore

struct BuildingPickerView: View {
    let maps: [BuildingMap]
    let onPick: (BuildingMap) -> Void
    let onExit: () -> Void

    var body: some View {
        NavScreen(
            title: "Choose a building",
            subtitle: maps.isEmpty ? "No maps on this phone yet" : "\(maps.count) maps on this phone",
            prompt: maps.isEmpty
                ? "There are no maps on this phone yet. Ask a volunteer to scan the building or share a map."
                : "Choose a building. \(maps.count) maps. Swipe or explore the screen to hear them."
        ) {
            if maps.isEmpty {
                NavInfoRow(systemImage: "map", text: "Ask a volunteer to scan the building, or receive a map with Share maps on the home screen.")
            }
            VStack(spacing: Theme.Space.m) {
                ForEach(maps) { map in
                    CardRow(title: map.name,
                            detail: "\(map.destinations.count) \(map.destinations.count == 1 ? "place" : "places")",
                            systemImage: "building.2", dark: true,
                            hint: "Opens the list of places in this building.") { onPick(map) }
                }
            }
            HeroButton(title: "Exit Navigate", systemImage: "xmark", style: .navSecondary,
                       hint: "Returns to the home screen.", action: onExit)
        }
    }
}
