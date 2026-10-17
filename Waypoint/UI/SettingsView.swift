//
// File:     Waypoint/UI/SettingsView.swift
// Owner:    U3 (UI flows)
// Purpose:  Settings sheet opened from the gear on the home screen (docs/UI_PLAN.md §8):
//             * Interface: Classic (default - the original VolunteerView / NavigatorView, untouched) or New;
//             * Data source for the new interface: Demo data / Simulated walk / Live;
//             * accessibility options: spoken prompts when VoiceOver is off, open straight into Navigate;
//             * what this iPhone can do (LiDAR, VoiceOver).
// Status:   SCAFFOLD.
//
import SwiftUI
import UIKit

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss

    @AppStorage(UIPrefs.newInterface) private var newInterface = false
    @AppStorage(UIPrefs.serviceMode) private var serviceModeRaw = ServiceMode.mock.rawValue
    @AppStorage(UIPrefs.spokenPrompts) private var spokenPrompts = true
    @AppStorage(UIPrefs.openInNavigate) private var openInNavigate = false

    private var serviceMode: ServiceMode { ServiceMode(rawValue: serviceModeRaw) ?? .mock }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Interface", selection: $newInterface) {
                        Text("Classic").tag(false)
                        Text("New").tag(true)
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Interface")
                } footer: {
                    Text("Classic keeps the original screens. New shows the redesigned scanner and the accessible navigator.")
                }

                Section {
                    Picker("Data source", selection: $serviceModeRaw) {
                        ForEach(ServiceMode.allCases) { mode in
                            Text(mode.title).tag(mode.rawValue)
                        }
                    }
                    Text(serviceMode.detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if serviceMode == .live && !DeviceCapabilities.hasLiDAR {
                        Label("This iPhone has no LiDAR: scanning will use demo data.", systemImage: "info.circle")
                            .font(.footnote)
                    }
                } header: {
                    Text("Data source (new interface)")
                }
                .disabled(!newInterface)

                Section {
                    Toggle("Spoken prompts when VoiceOver is off", isOn: $spokenPrompts)
                    Toggle("Open in Navigate on launch", isOn: $openInNavigate)
                } header: {
                    Text("Accessibility")
                } footer: {
                    Text("Spoken prompts read each navigator screen aloud for people who do not use VoiceOver. Open in Navigate is for the blind user's own phone (new interface only).")
                }
                .disabled(!newInterface)

                Section("This iPhone") {
                    LabeledContent("LiDAR", value: DeviceCapabilities.hasLiDAR ? "Yes" : "No")
                    LabeledContent("VoiceOver", value: UIAccessibility.isVoiceOverRunning ? "On" : "Off")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
