//
// File:     Waypoint/Services/Announcer.swift
// Owner:    U3 (UI flows)
// Purpose:  The one place the new UI talks to the user (docs/UI_PLAN.md §7.1). Everything audible goes
//           through `Speaker`, the app's SINGLE voice (D-026, 2026-10-17): this class used to own its
//           own AVSpeechSynthesizer and talked over guidance speech at arrival, in a second voice.
//             * `say`    = state changes ("Position found"). Spoken aloud whether or not VoiceOver is
//                          running. It is deliberately NOT posted as a VoiceOver announcement any
//                          more: that was a second stream on top of the guidance voice.
//             * `prompt` = screen introductions ("Where to?"). Only when VoiceOver is OFF, because
//                          with VoiceOver on the focused heading is read automatically.
//             * `voiceOverOnly` = sighted-scanner chatter. Still a VoiceOver announcement, never aloud.
//           "Spoken prompts" (a sighted-user preference) does not silence `say` while VoiceOver runs.
//           `prompt` = screen introductions ("Where to?") - only when VoiceOver is OFF, because with VoiceOver
//                      on the focused heading is read automatically and a prompt would be heard twice.
//           Guidance instructions in Live/Simulated mode are NOT sent here; SpeechGuide speaks them.
// Threading: main thread only.
// Status:   SCAFFOLD, UNVERIFIED ON DEVICE.
//
import AVFoundation
import SwiftUI
import UIKit

enum Announcer {

    static var spokenPromptsEnabled: Bool {
        UserDefaults.standard.object(forKey: UIPrefs.spokenPrompts) as? Bool ?? true
    }

    static var isVoiceOverRunning: Bool { UIAccessibility.isVoiceOverRunning }

    /// A state change the user must hear. `interrupt` cuts off the phone's own voice (VoiceOver queues).
    static func say(_ text: String, interrupt: Bool = false) {
        guard !text.isEmpty else { return }
        // Spoken prompts off is a sighted-user preference; a VoiceOver user still needs state changes,
        // so with VoiceOver running we speak regardless of that switch.
        guard spokenPromptsEnabled || isVoiceOverRunning else { return }
        speak(text, interrupt: interrupt)
    }

    /// A screen introduction; silent when VoiceOver is on (it reads the focused heading instead).
    static func prompt(_ text: String, interrupt: Bool = true) {
        guard !isVoiceOverRunning, spokenPromptsEnabled, !text.isEmpty else { return }
        speak(text, interrupt: interrupt)
    }

    /// For sighted-user screens (scanner): only tells VoiceOver users, never speaks aloud.
    static func voiceOverOnly(_ text: String) {
        guard isVoiceOverRunning, !text.isEmpty else { return }
        AccessibilityNotification.Announcement(text).post()
    }

    static func stop() {
        Speaker.shared.stop()
    }

    private static func speak(_ text: String, interrupt: Bool) {
        Speaker.shared.say(text, priority: interrupt ? .high : .normal)
    }
}

/// Read-only check of the current audio output (never changes the audio session).
enum AudioRoute {
    static var headphonesConnected: Bool {
        let headphonePorts: [AVAudioSession.Port] = [.headphones, .bluetoothA2DP, .bluetoothLE, .bluetoothHFP]
        return AVAudioSession.sharedInstance().currentRoute.outputs.contains { headphonePorts.contains($0.portType) }
    }
}
