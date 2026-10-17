//
// File:     Waypoint/Services/Announcer.swift
// Owner:    U3 (UI flows)
// Purpose:  The one place the new UI talks to the user (docs/UI_PLAN.md §7.1):
//             * VoiceOver ON  -> `AccessibilityNotification.Announcement` (VoiceOver reads it in its own voice
//                                and queues it with whatever it is already reading).
//             * VoiceOver OFF -> the phone speaks with AVSpeechSynthesizer when "Spoken prompts" is on, so a
//                                blindfolded tester who does not use VoiceOver still hears every step.
//           `say`    = state changes ("Position found") - spoken in both cases.
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

    private static let synthesizer = AVSpeechSynthesizer()

    static var spokenPromptsEnabled: Bool {
        UserDefaults.standard.object(forKey: UIPrefs.spokenPrompts) as? Bool ?? true
    }

    static var isVoiceOverRunning: Bool { UIAccessibility.isVoiceOverRunning }

    /// A state change the user must hear. `interrupt` cuts off the phone's own voice (VoiceOver queues).
    static func say(_ text: String, interrupt: Bool = false) {
        guard !text.isEmpty else { return }
        if isVoiceOverRunning {
            AccessibilityNotification.Announcement(text).post()
        } else if spokenPromptsEnabled {
            speak(text, interrupt: interrupt)
        }
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
        synthesizer.stopSpeaking(at: .immediate)
    }

    private static func speak(_ text: String, interrupt: Bool) {
        if interrupt { synthesizer.stopSpeaking(at: .immediate) }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        synthesizer.speak(utterance)
    }
}

/// Read-only check of the current audio output (never changes the audio session).
enum AudioRoute {
    static var headphonesConnected: Bool {
        let headphonePorts: [AVAudioSession.Port] = [.headphones, .bluetoothA2DP, .bluetoothLE, .bluetoothHFP]
        return AVAudioSession.sharedInstance().currentRoute.outputs.contains { headphonePorts.contains($0.portType) }
    }
}
