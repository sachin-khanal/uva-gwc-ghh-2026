//
// File:     Waypoint/UI/Scanner/ScanReviewView.swift
// Owner:    U3 (UI flows)
// Purpose:  S4 "Review": the saved map as a top-down plan (PlanView), health warnings (MapHealth) and the list
//           of tagged places, which can be renamed. Renaming rewrites map.json via MapStore.save and bumps
//           `version` so peers treat the edit as newer; the ARWorldMap file is untouched.
//           Deleting places is intentionally not offered (it would need graph surgery).
//           3D model preview is a placeholder until mesh export exists (ROADMAP U3.8).
// Status:   SCAFFOLD.
//
import SwiftUI
import WaypointCore

struct ScanReviewView: View {
    @EnvironmentObject var app: AppState
    let onShare: (BuildingMap) -> Void
    let onDone: () -> Void

    @State private var map: BuildingMap
    @State private var renaming: MapNode?
    @State private var renameText = ""
    @State private var saveError: String?
    @State private var modelReady = false
    @State private var showModel = false
    private let openedAt = Date()
    /// Polls for the model file while one may still be coming. `modelReady` used to be read ONCE in
    /// `.onAppear`, so a model that landed a few seconds later was never noticed and the card went on
    /// claiming there was none until you left the screen and came back (device report 2026-10-18).
    private let modelPoll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    init(map: BuildingMap, onShare: @escaping (BuildingMap) -> Void, onDone: @escaping () -> Void) {
        _map = State(initialValue: map)
        self.onShare = onShare
        self.onDone = onDone
    }

    private var places: [MapNode] { map.nodes.filter { $0.kind != .corridor } }
    private var warnings: [MapWarning] { MapHealth.check(map) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                Button(action: onDone) {
                    Label("Scans", systemImage: "chevron.left").font(.body.weight(.semibold))
                }
                .accessibilityLabel("Back to scans")

                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    Text("Review")
                        .font(.largeTitle.weight(.bold))
                        .fontDesign(.rounded)
                        .accessibilityAddTraits(.isHeader)
                    Text(map.name).font(.headline).foregroundStyle(.secondary)
                }

                PlanView(map: map)
                    .frame(height: 300)
                Text("Pinch to zoom. Double tap to reset.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)

                stats
                roomSizes

                if warnings.isEmpty {
                    Banner(text: "Looks good: every place is labelled and reachable.", kind: .info)
                } else {
                    VStack(alignment: .leading, spacing: Theme.Space.s) {
                        Text("Check before sharing").font(.title3.weight(.semibold)).accessibilityAddTraits(.isHeader)
                        ForEach(Array(warnings.enumerated()), id: \.offset) { _, warning in
                            Banner(text: warning.message)
                        }
                    }
                }
                if let saveError { Banner(text: saveError, kind: .error) }
                // Scan file near or over the 50 MB sharing limit (SharePolicy): say so before the person tries to share it.
                let shareVerdict = app.store.shareVerdict(mapId: map.id)
                if let why = SharePolicy.message(shareVerdict) { Banner(text: why, kind: shareVerdict.isLocalOnly ? .warning : .info) }

                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    Text("Places").font(.title3.weight(.semibold)).accessibilityAddTraits(.isHeader)
                    if places.isEmpty {
                        Text("No tagged places.").foregroundStyle(.secondary)
                    }
                    ForEach(places) { node in
                        CardRow(title: node.label ?? "Unnamed \(node.kind.displayName.lowercased())",
                                detail: node.kind.displayName, systemImage: node.kind.symbolName,
                                badges: (node.label ?? "").isEmpty ? ["Needs label"] : [],
                                showsChevron: false, hint: "Double tap to rename.") {
                            renameText = node.label ?? ""
                            renaming = node
                        }
                    }
                }

                model3D

                VStack(spacing: Theme.Space.m) {
                    HeroButton(title: "Save & share", subtitle: "Send to nearby phones or the cloud",
                               systemImage: "square.and.arrow.up") { onShare(map) }
                    HeroButton(title: "Done", style: .secondary, action: onDone)
                }
            }
            .padding(Theme.Space.l)
        }
        .background(Theme.screenBackground)
        .fullScreenCover(isPresented: $showModel) {
            ModelViewerView(map: map, urls: app.store.modelURLs(mapId: map.id, segmentIds: map.segmentIds), onClose: { showModel = false })
        }
        .onAppear { modelReady = app.store.hasModel(mapId: map.id, segmentIds: map.segmentIds) }
        .onReceive(modelPoll) { _ in
            guard !modelReady else { return }
            modelReady = app.store.hasModel(mapId: map.id, segmentIds: map.segmentIds)
        }
        .alert("Rename place", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Label", text: $renameText)
                .textInputAutocapitalization(.words)
            Button("Save") { applyRename() }
            Button("Cancel", role: .cancel) { renaming = nil }
        } message: {
            Text("Use the name on the sign, e.g. Room 204.")
        }
    }

    private var stats: some View {
        HStack(spacing: Theme.Space.m) {
            stat("\(map.nodes.count)", "points")
            stat("\(map.destinations.count)", "places")
            stat("\(map.edges.count)", "paths")
            stat("\(roomsWithExtents.count)", "rooms sized")
        }
    }

    /// Rooms whose floor area the scan worked out (RoomExtent). Drawn on the plan above as dashed
    /// rectangles; listed here with their measurements so a bad extraction is obvious on review
    /// rather than during a walk.
    private var roomsWithExtents: [MapNode] {
        map.nodes.filter { $0.kind == .room && $0.extent != nil }
    }

    @ViewBuilder
    private var roomSizes: some View {
        if !roomsWithExtents.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Text("Room boundaries").font(.headline)
                ForEach(roomsWithExtents) { room in
                    if let extent = room.extent {
                        HStack {
                            Text(room.label ?? "Room").font(.subheadline)
                            Spacer()
                            Text(String(format: "%.1f x %.1f m · %.0f m2",
                                        extent.halfExtents.x * 2, extent.halfExtents.y * 2,
                                        extent.areaSquareMeters))
                                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("\(room.label ?? "Room"), " + String(format: "%.0f square metres", extent.areaSquareMeters))
                    }
                }
                Text("Rooms without a measured boundary fall back to a fixed arrival distance.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.title2.weight(.bold)).fontDesign(.rounded).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 64)
        .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    /// The 3D model of this scan (USDZ written at save time, see MeshExporter). It is built in the background after saving, so the
    /// card first says it is being built, then offers the viewer. Scans without a model (demo scans, the sample map, scans made before
    /// this feature) say so plainly.
    private var model3D: some View {
        let ready = modelReady
        return Button {
            if ready { showModel = true }
        } label: {
            HStack(spacing: Theme.Space.m) {
                Image(systemName: ready ? "cube.fill" : "cube.transparent").font(.title).foregroundStyle(Theme.accent).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("3D model").font(.headline)
                    Text(ready ? "Open the scan as a 3D model with the places pinned on it."
                         : modelWaiting ? "Building the 3D model from the scan…"
                         : "No 3D model for this scan (only real LiDAR scans saved with this version have one).")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if ready { Image(systemName: "chevron.right").foregroundStyle(.secondary).accessibilityHidden(true) }
                else if modelWaiting { ProgressView() }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.Space.l)
            .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!ready)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(ready ? .isButton : [])
        .accessibilityIdentifier("review.model3d")
        .task {
            // A scan that was just saved is still being exported: look for the file for up to a minute.
            for _ in 0..<60 {
                if app.store.hasModel(mapId: map.id, segmentIds: map.segmentIds) { modelReady = true; break }
                if !savedRecently { break } // an older scan: nothing is coming
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    /// True while a model may still be coming (the review opened right after a save).
    ///
    /// This is a GUESS about timing, not a result, so it must never be used to claim the opposite. The
    /// 60 s cut-off used to flip the card to "No 3D model for this scan" whether the export had failed,
    /// was still running, or had already SUCCEEDED - a stopwatch presented as an outcome. The real
    /// answer now arrives via `modelPoll` (the file appearing) or `controller.modelStatus` (the
    /// exporter's own verdict, including its error text); a 3.5 M-triangle scan takes minutes, well past
    /// any fixed window. Widened to match `MeshExporter`'s realistic worst case and kept only as the
    /// spinner's condition.
    private var modelWaiting: Bool { !modelReady && Date().timeIntervalSince(openedAt) < 600 && savedRecently }

    /// The map file was written in the last two minutes, i.e. this review follows a fresh scan whose model is still being built.
    private var savedRecently: Bool {
        let file = app.store.directory(for: map.id).appendingPathComponent("map.json")
        guard let modified = (try? FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate]) as? Date else { return false }
        return Date().timeIntervalSince(modified) < 120
    }

    private func applyRename() {
        guard let node = renaming, let index = map.nodes.firstIndex(where: { $0.id == node.id }) else { return }
        renaming = nil
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        var updated = map
        updated.nodes[index].label = trimmed.isEmpty ? nil : trimmed
        updated.version += 1
        do {
            try app.store.save(updated)
            map = updated
            saveError = nil
            app.reloadMaps()
            Announcer.voiceOverOnly("Renamed to \(trimmed.isEmpty ? "no label" : trimmed)")
        } catch {
            saveError = "Could not save the new name: \(error.localizedDescription)"
        }
    }
}
