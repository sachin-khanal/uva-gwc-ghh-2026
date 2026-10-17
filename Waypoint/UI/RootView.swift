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
                        Button("Home") { app.mode = .none }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Share maps") { showSync = true }
                        .accessibilityLabel("Share maps with nearby phones")
                }
            }
            .sheet(isPresented: $showSync) { SyncView() }
        }
    }

    private var modePicker: some View {
        VStack(spacing: 24) {
            bigButton("Navigate", subtitle: "Get guided to a room", systemImage: "figure.walk") {
                app.mode = .navigator
            }
            bigButton("Scan a building", subtitle: "Volunteer: record a map", systemImage: "camera.viewfinder") {
                app.mode = .volunteer
            }
            Text("\(app.maps.count) map(s) on this phone")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .padding(24)
    }

    private func bigButton(_ title: String, subtitle: String, systemImage: String,
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
    }
}
