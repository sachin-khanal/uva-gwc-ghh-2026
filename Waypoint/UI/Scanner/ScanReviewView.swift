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

                placeholder3D

                VStack(spacing: Theme.Space.m) {
                    HeroButton(title: "Save & share", subtitle: "Send to nearby phones or the cloud",
                               systemImage: "square.and.arrow.up") { onShare(map) }
                    HeroButton(title: "Done", style: .secondary, action: onDone)
                }
            }
            .padding(Theme.Space.l)
        }
        .background(Theme.screenBackground)
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

    private var placeholder3D: some View {
        HStack(spacing: Theme.Space.m) {
            Image(systemName: "cube.transparent").font(.title).foregroundStyle(Theme.accent).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("3D model").font(.headline)
                Text("Coming soon: mesh export and 3D preview (roadmap U3.8).")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Space.l)
        .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .accessibilityElement(children: .combine)
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
