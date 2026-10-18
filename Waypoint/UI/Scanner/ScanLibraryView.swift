//
// File:     Waypoint/UI/Scanner/ScanLibraryView.swift
// Owner:    U3 (UI flows)
// Purpose:  S1 "Scans": the maps on this phone as cards (name, points, places, Demo/no-world-map badge),
//           a big "New scan" button, "Extend a map" (picker of saved scan areas -> real extension via CaptureController, ROADMAP U1.10), Share (opens the existing
//           SyncView unchanged, keeping its approval alerts - UI_PLAN rule R5) and Delete (always confirmed).
// Status:   SCAFFOLD, UNVERIFIED ON DEVICE.
//
import SwiftUI
import WaypointCore

struct ScanLibraryView: View {
    @EnvironmentObject var app: AppState
    let onNewScan: () -> Void
    /// The volunteer picked a saved scan area to extend (see ExtendChoices).
    let onExtend: (ExtendOption, BuildingMap) -> Void
    let onOpen: (BuildingMap) -> Void

    @State private var showSync = false
    @State private var showExtend = false
    @State private var pendingDelete: BuildingMap?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                header

                HeroButton(title: "New scan", subtitle: "Walk the space once and tag places",
                           systemImage: "viewfinder", hint: "Starts setting up a new scan.", action: onNewScan)
                HeroButton(title: "Extend a map", subtitle: "Add a wing to an existing map",
                           systemImage: "plus.square.on.square", style: .secondary) { showExtend = true }

                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    Text("On this phone")
                        .font(.title3.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                    if app.maps.isEmpty {
                        emptyState
                    } else {
                        ForEach(app.maps) { map in
                            HStack(spacing: Theme.Space.s) {
                                CardRow(title: map.name, detail: detail(for: map), systemImage: "building.2",
                                        badges: badges(for: map), hint: "Opens the map review.") { onOpen(map) }
                                // Visible control as well as the context menu: a long press is not
                                // discoverable, and this screen is used by sighted volunteers.
                                Button(role: .destructive) { pendingDelete = map } label: {
                                    Image(systemName: "trash")
                                        .font(.title3)
                                        .frame(width: 44, height: 44) // full-size tap target
                                }
                                .accessibilityLabel("Delete \(map.name)")
                                .accessibilityHint("Asks for confirmation first.")
                            }
                                .contextMenu {
                                    Button { showSync = true } label: { Label("Share", systemImage: "square.and.arrow.up") }
                                    Button(role: .destructive) { pendingDelete = map } label: { Label("Delete", systemImage: "trash") }
                                }
                                .accessibilityAction(named: "Share") { showSync = true }
                                .accessibilityAction(named: "Delete") { pendingDelete = map }
                        }
                    }
                }
            }
            .padding(Theme.Space.l)
        }
        .background(Theme.screenBackground)
        .sheet(isPresented: $showSync) { SyncView() }
        .sheet(isPresented: $showExtend) { extendPicker }
        .confirmationDialog(
            "Delete \(pendingDelete?.name ?? "this map")?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete map", role: .destructive) { deletePending() }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("The map and its saved scan are removed from this phone. Copies on other phones or in the cloud are not affected.")
        }
        .onAppear { app.reloadMaps() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Text("Scans")
                .font(.largeTitle.weight(.bold))
                .fontDesign(.rounded)
                .accessibilityAddTraits(.isHeader)
            HStack(spacing: Theme.Space.s) {
                Text("Record maps for people to navigate")
                    .foregroundStyle(.secondary)
                if ServiceMode.current == .mock || !DeviceCapabilities.hasLiDAR { MockBadge() }
            }
            .font(.subheadline)
        }
    }

    private var emptyState: some View {
        VStack(spacing: Theme.Space.m) {
            Image(systemName: "map")
                .font(.system(size: 44))
                .foregroundStyle(Theme.accent)
                .accessibilityHidden(true)
            Text("No maps yet").font(.headline)
            Text("Start a new scan to create the first map.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(Theme.Space.xl)
        .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private var canExtendHere: Bool { ServiceMode.current == .live && DeviceCapabilities.hasLiDAR }

    private var extendOptions: [ExtendOption] {
        ExtendChoices.options(maps: app.maps) { mapId, segment in
            FileManager.default.fileExists(atPath: app.store.worldMapURL(mapId: mapId, segmentId: segment).path)
        }
    }

    /// "Extend a map": choose a saved scan area. The scanner then waits until it has found its place in that area (the phone must be
    /// standing near a mapped corridor), and only then records the new part, attached to the old map.
    private var extendPicker: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    Text("Pick the area you are STANDING IN, then stand where you first started scanning it and hold still. The phone has to recognise that area before you can add to it - choosing one you are not in will never work, however long you wait.")
                        .foregroundStyle(.secondary)
                    if !canExtendHere {
                        Banner(text: "Extending needs Live mode (Settings) on an iPhone with LiDAR.", kind: .warning)
                    } else if extendOptions.isEmpty {
                        Banner(text: "No scan on this phone has its saved position data. Make a new scan, or download a map together with its scan files.", kind: .info)
                    }
                    if canExtendHere {
                        ForEach(extendOptions) { option in
                            if let map = app.maps.first(where: { $0.id == option.mapId }) {
                                // Say WHERE the area is, not just its number: "Scan area 2 of 2" gave the
                                // volunteer nothing to choose on, and picking the wrong one asks ARKit to
                                // recognise a part of the building they are not in (device report 2026-10-18).
                                CardRow(title: "\(option.mapName) · \(option.areaTitle)",
                                        detail: "\(option.isOriginal ? "Original scan" : "Added later") · \(option.whereItIs)",
                                        systemImage: "plus.square.on.square",
                                        hint: "Starts extending this map. Stand near a place you already scanned.") {
                                    showExtend = false
                                    onExtend(option, map)
                                }
                            }
                        }
                    }
                }
                .padding(Theme.Space.l)
            }
            .background(Theme.screenBackground)
            .navigationTitle("Extend a map")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Cancel") { showExtend = false } } }
        }
        .presentationDetents([.medium, .large])
    }

    private func detail(for map: BuildingMap) -> String {
        let places = map.destinations.count
        return "\(map.nodes.count) points · \(places) \(places == 1 ? "place" : "places") · v\(map.version)"
    }

    private func badges(for map: BuildingMap) -> [String] {
        hasWorldMap(map) ? [] : ["No position data"]
    }

    /// Maps without a saved ARWorldMap (sample map, demo scans) can only be used with Demo data / Simulated walk.
    private func hasWorldMap(_ map: BuildingMap) -> Bool {
        map.segmentIds.contains { segment in
            FileManager.default.fileExists(atPath: app.store.worldMapURL(mapId: map.id, segmentId: segment).path)
        }
    }

    private func deletePending() {
        guard let map = pendingDelete else { return }
        pendingDelete = nil
        // AppState owns deletion so the per-map UI state (recents, pending hand-off) goes with it.
        if app.deleteMap(map) {
            Announcer.voiceOverOnly("\(map.name) deleted")
        } else {
            Announcer.voiceOverOnly("Could not delete \(map.name)")
        }
    }
}
