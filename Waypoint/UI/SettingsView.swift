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
import WaypointCore
import UIKit

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss

    @AppStorage(UIPrefs.newInterface) private var newInterface = UIPrefs.newInterfaceDefault
    @AppStorage(UIPrefs.serviceMode) private var serviceModeRaw = ServiceMode.defaultMode.rawValue
    @AppStorage(UIPrefs.debugOverlay) private var debugOverlay = false
    @AppStorage(UIPrefs.visualFingerprints) private var visualFingerprints = false
    @AppStorage(UIPrefs.spokenPrompts) private var spokenPrompts = true
    @AppStorage(UIPrefs.openInNavigate) private var openInNavigate = false
    @AppStorage(UIPrefs.speakViaVoiceOver) private var speakViaVoiceOver = true
    @AppStorage(UIPrefs.richNarration) private var richNarration = true

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
                    Toggle("Show debug overlay while guiding", isOn: $debugOverlay)
                    Toggle("Use visual fingerprints to find you", isOn: $visualFingerprints)
                    Text("Faster relocalization, but the match is approximate and its distance threshold is not calibrated yet. Turn it off if the route or your position looks wrong.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text("Sighted debugging: the camera and the route the app computed. Not for the blind user.")
                        .font(.footnote).foregroundStyle(.secondary)
                } header: {
                    Text("Accessibility")
                } footer: {
                    Text("Spoken prompts read each navigator screen aloud for people who do not use VoiceOver. Open in Navigate is for the blind user's own phone (new interface only).")
                }
                .disabled(!newInterface)

                Section {
                    NavigationLink("Voice and speed") { VoiceSettingsView() }
                    Toggle("Speak through VoiceOver when it is on", isOn: $speakViaVoiceOver)
                    Toggle("Richer wording (Gemini)", isOn: $richNarration)
                } header: {
                    Text("Voice and wording")
                } footer: {
                    Text("With VoiceOver on, guidance uses your VoiceOver voice and speed and never talks over it. Richer wording rewrites only the calm lines (the opening, landmarks, far-off countdowns) and sends just that one sentence to Google Gemini; warnings, turns and arrival are never sent. If it is slow, off or unavailable you hear the plain sentence.")
                }

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
