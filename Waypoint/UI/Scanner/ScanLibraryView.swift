//
// File:     Waypoint/UI/Scanner/ScanLibraryView.swift
// Owner:    U3 (UI flows)
// Purpose:  S1 "Scans": the maps on this phone as cards (name, points, places, Demo/no-world-map badge),
//           a big "New scan" button, "Extend a map" (placeholder until ROADMAP U1.10), Share (opens the existing
//           SyncView unchanged, keeping its approval alerts - UI_PLAN rule R5) and Delete (always confirmed).
// Status:   SCAFFOLD, UNVERIFIED ON DEVICE.
//
import SwiftUI
import WaypointCore

struct ScanLibraryView: View {
    @EnvironmentObject var app: AppState
    let onNewScan: () -> Void
    let onOpen: (BuildingMap) -> Void

    @State private var showSync = false
    @State private var showExtendInfo = false
    @State private var pendingDelete: BuildingMap?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                header

                HeroButton(title: "New scan", subtitle: "Walk the space once and tag places",
                           systemImage: "viewfinder", hint: "Starts setting up a new scan.", action: onNewScan)
                HeroButton(title: "Extend a map", subtitle: "Add a wing to an existing map",
                           systemImage: "plus.square.on.square", style: .secondary) { showExtendInfo = true }

                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    Text("On this phone")
                        .font(.title3.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                    if app.maps.isEmpty {
                        emptyState
                    } else {
                        ForEach(app.maps) { map in
                            CardRow(title: map.name, detail: detail(for: map), systemImage: "building.2",
                                    badges: badges(for: map), hint: "Opens the map review.") { onOpen(map) }
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
        .sheet(isPresented: $showExtendInfo) { extendInfo }
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

    private var extendInfo: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            Image(systemName: "hammer")
                .font(.largeTitle)
                .foregroundStyle(Theme.accent)
                .accessibilityHidden(true)
            Text("Coming soon").font(.title2.weight(.bold)).accessibilityAddTraits(.isHeader)
            Text("Extending a map means finding your position in an existing scan first, then walking new areas. It is being built in the scanning engine (roadmap task U1.10) and will appear here.")
                .foregroundStyle(.secondary)
            HeroButton(title: "OK", style: .secondary) { showExtendInfo = false }
        }
        .padding(Theme.Space.xl)
        .presentationDetents([.medium])
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
        do {
            try app.store.delete(id: map.id)
            Announcer.voiceOverOnly("\(map.name) deleted")
        } catch {
            Log.app.error("delete failed: \(error.localizedDescription)")
        }
        app.reloadMaps()
    }
}
