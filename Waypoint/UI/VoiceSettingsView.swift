//
// File:     Waypoint/UI/VoiceSettingsView.swift
// Owner:    B (Navigation/Feedback)
// Purpose:  Settings > Voice: choose how the app SPEAKS when VoiceOver is off. Pick any installed voice (tap = hear it), set the speaking speed,
//           and hear a sample sentence. Logic: WaypointCore `VoiceCatalog` / `SpeechRate`; playback: `Speaker.preview`.
// VoiceOver: while VoiceOver is running the app uses the person's own VoiceOver voice and speed instead (D-046); this screen says so.
// Status:   SCAFFOLD, UNVERIFIED ON DEVICE (what the previews sound like; whether every installed voice can be selected by identifier).
//
import SwiftUI
import UIKit
import WaypointCore

struct VoiceSettingsView: View {

    @AppStorage(UIPrefs.guidanceVoice) private var source = VoiceSource.phone.rawValue
    @AppStorage(UIPrefs.guidanceVoiceId) private var chosenId = ""
    @AppStorage(UIPrefs.speechRate) private var rate = SpeechRate.defaultFactor

    private static let sample = "Room 206 on your left. In 5 meters, turn right."

    private var rows: [VoiceRow] { Speaker.voiceRows }

    var body: some View {
        Form {
            if UIAccessibility.isVoiceOverRunning {
                Section {
                    Text("VoiceOver is on, so guidance is spoken through VoiceOver in your own VoiceOver voice and speed. These settings apply when VoiceOver is off.")
                        .font(.footnote)
                }
            }

            Section {
                Picker("Voice", selection: $source) {
                    Text("This iPhone's voice").tag(VoiceSource.phone.rawValue)
                    Text("Waypoint's Siri pick").tag(VoiceSource.app.rawValue)
                    Text("A voice I choose").tag(VoiceSource.chosen.rawValue)
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } header: {
                Text("Which voice")
            } footer: {
                Text("\"This iPhone's voice\" is the one you set up in Settings > Accessibility > Spoken Content.")
            }

            if source == VoiceSource.chosen.rawValue {
                Section {
                    ForEach(rows) { row in
                        Button {
                            chosenId = row.identifier
                            Speaker.shared.preview(Self.sample, voiceIdentifier: row.identifier, factor: rate)
                        } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(row.title).foregroundStyle(.primary)
                                    Text(row.detail).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if row.identifier == chosenId { Image(systemName: "checkmark") }
                            }
                        }
                        .accessibilityLabel("\(row.title), \(row.detail)")
                        .accessibilityAddTraits(row.identifier == chosenId ? .isSelected : [])
                        .accessibilityHint("Double tap to choose and hear this voice.")
                    }
                } header: {
                    Text("Installed voices")
                } footer: {
                    if VoiceCatalog.suggestsBetterVoice(rows) {
                        Text("Only compact voices are installed. For a more natural voice, download an Enhanced or Premium one in Settings > Accessibility > Spoken Content > Voices.")
                    }
                }
            }

            Section {
                HStack {
                    Text("Speed")
                    Slider(value: $rate, in: SpeechRate.range, step: 0.05)
                        .accessibilityLabel("Speaking speed")
                        .accessibilityValue(String(format: "%.2f times normal", rate))
                    Text(String(format: "%.2f×", rate)).monospacedDigit().foregroundStyle(.secondary)
                }
                Button("Hear a sample") {
                    Speaker.shared.preview(Self.sample, voiceIdentifier: previewVoice, factor: rate)
                }
            } header: {
                Text("How fast")
            }
        }
        .navigationTitle("Voice")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { Speaker.shared.stop() }
    }

    /// The voice the current choice would use right now (nil = the phone's own default, as in guidance).
    private var previewVoice: String? {
        Speaker.previewVoiceIdentifier(source: VoiceSource(rawValue: source) ?? .phone, chosen: chosenId.isEmpty ? nil : chosenId)
    }
}
