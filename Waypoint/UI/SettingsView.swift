//
// File:     Waypoint/UI/SettingsView.swift
// Owner:    U3 (UI flows)
// Purpose:  Settings sheet opened from the gear on the home screen.
//             * Navigation (everyone): spoken prompts when VoiceOver is off, open straight into Navigate.
//             * Debugging (one switch, "Show debugging tools", OFF by default). Off = a clean app: New interface,
//               Live on a LiDAR iPhone / Demo data otherwise, no developer options, no test tools on any screen.
//               On = the developer options below appear again with whatever was chosen before
//               (UIPrefs.debugTools, branch final-ui-changes 2026-10-18).
//             * Developer options (debugging on only): interface, data source, guiding debug overlay, visual
//               fingerprints, and what this iPhone can do.
// Status:   SCAFFOLD.
//
import SwiftUI
import UIKit

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss

    @AppStorage(UIPrefs.debugTools) private var debugTools = false
    @AppStorage(UIPrefs.newInterface) private var newInterface = UIPrefs.newInterfaceDefault
    @AppStorage(UIPrefs.serviceMode) private var serviceModeRaw = ServiceMode.defaultMode.rawValue
    @AppStorage(UIPrefs.debugOverlay) private var debugOverlay = false
    @AppStorage(UIPrefs.visualFingerprints) private var visualFingerprints = false
    @AppStorage(UIPrefs.spokenPrompts) private var spokenPrompts = true
    @AppStorage(UIPrefs.openInNavigate) private var openInNavigate = false

    private var serviceMode: ServiceMode { ServiceMode(rawValue: serviceModeRaw) ?? .mock }
    /// The interface actually in use (always New while debugging tools are off).
    private var usingNewInterface: Bool { debugTools ? newInterface : true }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Spoken prompts when VoiceOver is off", isOn: $spokenPrompts)
                    Toggle("Open in Navigate on launch", isOn: $openInNavigate)
                } header: {
                    Text("Navigation")
                } footer: {
                    Text("Spoken prompts read each navigator screen aloud for people who do not use VoiceOver. Open in Navigate is for the blind user's own phone.")
                }
                .disabled(!usingNewInterface)

                Section {
                    Toggle("Show debugging tools", isOn: $debugTools)
                        .accessibilityIdentifier("settings.debugTools")
                } header: {
                    Text("Debugging")
                } footer: {
                    Text(debugTools
                         ? "Developer options, test tools and scanner measurements are shown."
                         : "Off: the app uses the new interface with real scanning and positioning (demo data on iPhones without LiDAR). Turn on for developer options and test tools.")
                }

                if debugTools {
                    developerSections
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

    @ViewBuilder
    private var developerSections: some View {
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
            Toggle("Show debug overlay while guiding", isOn: $debugOverlay)
            Text("The camera and the route the app computed, for a sighted helper. Not for the blind user.")
                .font(.footnote).foregroundStyle(.secondary)
            Toggle("Use visual fingerprints to find you", isOn: $visualFingerprints)
            Text("Faster relocalization, but the match is approximate and its distance threshold is not calibrated yet. Turn it off if the route or your position looks wrong.")
                .font(.footnote).foregroundStyle(.secondary)
        } header: {
            Text("Developer options")
        }
        .disabled(!newInterface)

        Section("This iPhone") {
            LabeledContent("LiDAR", value: DeviceCapabilities.hasLiDAR ? "Yes" : "No")
            LabeledContent("VoiceOver", value: UIAccessibility.isVoiceOverRunning ? "On" : "Off")
        }
    }
}
