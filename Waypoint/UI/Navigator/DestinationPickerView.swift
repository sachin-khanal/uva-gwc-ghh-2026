//
// File:     Waypoint/UI/Navigator/DestinationPickerView.swift
// Owner:    U3 (UI flows)
// Purpose:  N2 "Where to?": search (keyboard dictation works out of the box), a "Say a destination" button
//           (demo: answers "Room 204"; real speech recognition is ROADMAP U2.11), recent destinations, and every
//           labelled place. Each row is ONE VoiceOver element that speaks a full sentence, e.g.
//           "Room 204. About 11 metres, 1 turn, no stairs." (RouteSummary, from the start of the map).
// Status:   SCAFFOLD.
//
import SwiftUI
import WaypointCore

struct DestinationPickerView: View {
    @ObservedObject var model: NavigatorModel
    let map: BuildingMap
    let onBack: () -> Void
    let onExit: () -> Void

    @State private var query = ""
    /// The demo "Say a destination" button is a test tool: shown only with Settings > Show debugging tools.
    @AppStorage(UIPrefs.debugTools) private var debugTools = false
    @FocusState private var searchFocused: Bool

    private var allPlaces: [MapNode] {
        map.destinations.sorted { ($0.label ?? "").localizedStandardCompare($1.label ?? "") == .orderedAscending }
    }

    private var filtered: [MapNode] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return allPlaces }
        let ids = Set(WaypointGraph(map: map).nodes(matchingLabel: q).map(\.id))
        return allPlaces.filter { ids.contains($0.id) }
    }

    private var recents: [MapNode] {
        Recents.ids(mapId: map.id).compactMap { id in allPlaces.first { $0.id == id } }
    }

    var body: some View {
        NavScreen(
            title: "Where to?",
            subtitle: map.name,
            prompt: "Where to? \(allPlaces.count) places in \(map.name). Explore the screen to hear them, or use the search field.",
            back: model.flow.mapCount > 1
                ? TopNavAction(title: "Buildings", hint: "Back to the list of buildings.", action: onBack) : nil,
            exit: TopNavAction(title: "Exit", systemImage: "xmark", hint: "Returns to the home screen.", action: onExit)
        ) {
            searchField

            if debugTools {
                HeroButton(title: "Say a destination", subtitle: "Demo: always hears “Room 204”",
                           systemImage: "mic.fill", style: .navSecondary,
                           hint: "Voice input is coming soon. This demo picks Room 204.") { voicePick() }
            }

            if query.isEmpty && !recents.isEmpty {
                section("Recent", places: recents)
            }
            if filtered.isEmpty {
                NavInfoRow(systemImage: "magnifyingglass", text: query.isEmpty ? "This map has no labelled places." : "No place matches “\(query)”.")
            } else {
                section(query.isEmpty ? "All places" : "Matches", places: filtered)
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: Theme.Space.m) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Theme.Nav.secondaryText)
                .accessibilityHidden(true)
            TextField("", text: $query, prompt: Text("Search, e.g. 204").foregroundStyle(Theme.Nav.secondaryText))
                .font(.title3)
                .foregroundStyle(Theme.Nav.text)
                .focused($searchFocused)
                .submitLabel(.search)
                .autocorrectionDisabled()
                .accessibilityLabel("Search places")
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.title3).foregroundStyle(Theme.Nav.secondaryText)
                }
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, Theme.Space.l)
        .frame(minHeight: 64)
        .background(Theme.Nav.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .strokeBorder(searchFocused ? Theme.Nav.primary : Theme.Nav.surfaceStroke, lineWidth: 2)
        }
    }

    private func section(_ title: String, places: [MapNode]) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text(title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(Theme.Nav.secondaryText)
                .accessibilityAddTraits(.isHeader)
            ForEach(places) { place in
                let summary = model.previewSummary(to: place, in: map)
                CardRow(title: place.label ?? place.kind.displayName,
                        detail: summary?.shortSummary ?? place.kind.displayName,
                        systemImage: place.kind.symbolName, dark: true,
                        hint: "Opens the route preview.",
                        accessibilityText: summary?.spokenSummary ?? (place.label ?? place.kind.displayName)) {
                    choose(place)
                }
            }
        }
    }

    private func choose(_ place: MapNode) {
        searchFocused = false
        model.chooseDestination(place, in: map)
    }

    private func voicePick() {
        let graph = WaypointGraph(map: map)
        let heard = "Room 204"
        if let match = graph.nodes(matchingLabel: heard).first(where: { node in allPlaces.contains { $0.id == node.id } }) {
            Announcer.say("Heard \(heard).", interrupt: true)
            choose(match)
        } else if let first = allPlaces.first {
            Announcer.say("Demo voice input. \(heard) is not on this map, choosing \(first.label ?? "the first place").", interrupt: true)
            choose(first)
        } else {
            Announcer.say("This map has no places to go to.", interrupt: true)
        }
    }
}
