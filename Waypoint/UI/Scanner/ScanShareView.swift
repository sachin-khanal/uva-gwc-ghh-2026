//
// File:     Waypoint/UI/Scanner/ScanShareView.swift
// Owner:    U3 (UI flows)
// Purpose:  S5 "Save & share": confirms the map is on this phone, opens the EXISTING SyncView (nearby phones,
//           cloud, AirDrop - unchanged, with its approval alerts, UI_PLAN rule R5), and offers
//           "Try it in Navigate", which opens the new Navigator with this map preselected.
// Status:   SCAFFOLD.
//
import SwiftUI
import WaypointCore

struct ScanShareView: View {
    @EnvironmentObject var app: AppState
    let map: BuildingMap
    let onBack: () -> Void
    let onDone: () -> Void

    @State private var showSync = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                TopNavBar(back: TopNavAction(title: "Review", hint: "Back to the map review.", action: onBack),
                          trailing: TopNavAction(title: "Done", hint: "Back to the list of scans.", action: onDone))

                VStack(spacing: Theme.Space.m) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 64))
                        .foregroundStyle(.green)
                        .accessibilityHidden(true)
                    Text("Saved on this phone")
                        .font(.title.weight(.bold))
                        .fontDesign(.rounded)
                        .accessibilityAddTraits(.isHeader)
                    Text(map.name).font(.headline).foregroundStyle(.secondary)
                    Text("\(map.destinations.count) places · version \(map.version)")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, Theme.Space.l)
                .accessibilityElement(children: .combine)

                HeroButton(title: "Share", subtitle: "Nearby phones, cloud library or AirDrop",
                           systemImage: "square.and.arrow.up") { showSync = true }
                HeroButton(title: "Try it in Navigate", subtitle: "Open this map in the navigator",
                           systemImage: "figure.walk", style: .secondary) { tryInNavigate() }
            }
            .padding(Theme.Space.l)
        }
        .background(Theme.screenBackground)
        .sheet(isPresented: $showSync) { SyncView() }
    }

    private func tryInNavigate() {
        UserDefaults.standard.set(map.id.uuidString, forKey: UIPrefs.pendingMapId)
        app.mode = .navigator
    }
}
