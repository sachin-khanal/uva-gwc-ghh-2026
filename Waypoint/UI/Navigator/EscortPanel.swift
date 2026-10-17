//
// File:     Waypoint/UI/Navigator/EscortPanel.swift
// Owner:    U3 (UI flows)
// Purpose:  Sheet for the SIGHTED escort / judge / developer during a walk: shows the data source and the raw
//           status from the guidance engine, plus test tools (inject a STOP obstacle in demo and simulated
//           modes; force "position lost", fail positioning or skip to arrival in demo mode only).
//           Reached from the small "Escort" button on the guiding screen, which VoiceOver skips.
// Status:   SCAFFOLD.
//
import SwiftUI
import WaypointCore

struct EscortPanel: View {
    @ObservedObject var model: NavigatorModel
    @Environment(\.dismiss) private var dismiss

    @State private var obstacle = false
    @State private var lost = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Status") {
                    LabeledContent("Data source", value: model.mode.title)
                    LabeledContent("Showing", value: model.guidance.headline)
                    LabeledContent("Destination", value: model.guidance.destinationLabel)
                    Text(model.guidance.rawStatus.isEmpty ? "–" : model.guidance.rawStatus)
                        .font(.footnote.monospaced())
                        .foregroundStyle(.secondary)
                }

                if model.supportsObstacleInjection || model.supportsDebugControls {
                    Section {
                        if model.supportsObstacleInjection {
                            Toggle("Obstacle 0.5 m ahead (STOP)", isOn: $obstacle)
                                .onChange(of: obstacle) { _, on in model.injectObstacle(on) }
                        }
                        if model.supportsDebugControls {
                            Toggle("Position lost", isOn: $lost)
                                .onChange(of: lost) { _, on in model.forceLost(on) }
                            Button("Fail positioning") {
                                model.forceFailure()
                                dismiss()
                            }
                            Button("Skip to arrival") {
                                model.skipToArrival()
                                dismiss()
                            }
                        }
                    } header: {
                        Text("Test tools")
                    } footer: {
                        Text("Only for testing. They change what the walker hears.")
                    }
                }

                Section {
                    Text("Walk beside the user with a hand ready. The user stops a route by holding the Stop button for one second.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Escort")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .onDisappear {
            // Never leave a fake obstacle or fake "lost" running after the panel closes.
            if obstacle { model.injectObstacle(false) }
            if lost { model.forceLost(false) }
        }
    }
}
