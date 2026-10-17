//
// File:     Waypoint/UI/RootView.swift
// Owner:    D (App/Sync/Integration)
// Purpose:  Launch screen: choose Volunteer (scan) or Navigator (get guided). Also hosts the
//           "Share maps" sheet (SyncView). Everything is large-button, VoiceOver-labelled UI.
// Status:   SCAFFOLD - functional but unstyled. Polish after integration milestone.
//
import SwiftUI

struct RootView: View {
    @EnvironmentObject var app: AppState
    @State private var showSync = false

    var body: some View {
        NavigationStack {
            Group {
                switch app.mode {
                case .none: modePicker
                case .volunteer: VolunteerView()
                case .navigator: NavigatorView()
                }
            }
            .navigationTitle("Waypoint")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if app.mode != .none {
                        Button("Home") { app.mode = .none }.accessibilityIdentifier("toolbar.home")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Share maps") { showSync = true }
                        .accessibilityLabel("Share maps with nearby phones")
                        .accessibilityIdentifier("toolbar.share")
                }
            }
            .sheet(isPresented: $showSync) { SyncView() }
            .task {
                // `-autoE2E YES`: run the headless end-to-end self-test once, then quit with its result.
                guard app.launchCommand == .e2e else { return }
                let ok = await E2ESelfTest.run(app: app)
                exit(ok ? 0 : 1)
            }
        }
    }

    private var modePicker: some View {
        VStack(spacing: 24) {
            bigButton("Navigate", id: "mode.navigate", subtitle: "Get guided to a room", systemImage: "figure.walk") {
                app.mode = .navigator
            }
            bigButton("Scan a building", id: "mode.scan", subtitle: "Volunteer: record a map", systemImage: "camera.viewfinder") {
                app.mode = .volunteer
            }
            Text("\(app.maps.count) map(s) on this phone")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .padding(24)
    }

    private func bigButton(_ title: String, id: String, subtitle: String, systemImage: String,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: systemImage).font(.largeTitle)
                VStack(alignment: .leading) {
                    Text(title).font(.title2).bold()
                    Text(subtitle).font(.subheadline)
                }
                Spacer()
            }
            .padding(24)
            .frame(maxWidth: .infinity, minHeight: 120)
            .background(.tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 20))
        }
        .accessibilityLabel("\(title). \(subtitle)")
        .accessibilityIdentifier(id) // stable id for UI tests (WaypointUITests)
    }
}
