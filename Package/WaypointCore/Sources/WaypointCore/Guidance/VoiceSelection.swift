//
// File:     Guidance/VoiceSelection.swift
// Module:   WaypointCore
// Owner:    B (Navigation/Feedback)
// Purpose:  Which voice the app speaks with, as a pure decision so it is testable without AVFoundation.
//           Order of preference (2026-10-18, requested by the team):
//             1. VoiceOver is running  -> use the user's ASSISTIVE settings (their VoiceOver voice and rate).
//                                         Guidance then sounds exactly like the rest of their phone.
//             1b. a voice the person picked in Settings, if it is still installed.
//             2. else the voice the user's iPhone already uses by default for their language (no voice is set
//                on the utterance, so iOS picks the one from Settings > Accessibility > Spoken Content).
//             3. FALLBACK ONLY: the app's own pick (`VoicePicker`: an installed Siri voice, else the best installed).
// Why:      The app used to override the phone with its own global Siri choice, which ignored what the person had
//           set up for themselves.
// Caveat:   Whether "no voice set" resolves to the person's Spoken Content voice is iOS behaviour we cannot test
//           here - UNVERIFIED ON DEVICE.
// Status:   DONE (logic, unit tested). `Speaker` applies the result.
//
import Foundation

public enum VoiceSource: String, Sendable {
    /// The voice the iPhone itself uses (default).
    case phone
    /// The app's own pick (`VoicePicker`).
    case app
    /// A voice the person picked in Settings (`VoiceCatalog`). If it is no longer installed, the phone's own default is used.
    case chosen
}

public struct VoiceDecision: Equatable, Sendable {
    /// nil = leave the utterance's voice unset, so iOS uses the phone's own default.
    public var voiceIdentifier: String?
    /// Speak with VoiceOver's own voice and rate (`AVSpeechUtterance.prefersAssistiveTechnologySettings`).
    public var useAssistiveSettings: Bool
}

public enum VoiceSelection {

    public static func choose(
        source: VoiceSource,
        chosenIdentifier: String? = nil,
        voiceOverRunning: Bool,
        phoneDefaultResolvable: Bool,
        candidates: [VoiceCandidate],
        language: String
    ) -> VoiceDecision {
        if voiceOverRunning {
            return VoiceDecision(voiceIdentifier: nil, useAssistiveSettings: true)
        }
        if source == .chosen, let id = chosenIdentifier, candidates.contains(where: { $0.identifier == id }) {
            return VoiceDecision(voiceIdentifier: id, useAssistiveSettings: false)
        }
        if source != .app, phoneDefaultResolvable {
            return VoiceDecision(voiceIdentifier: nil, useAssistiveSettings: false)
        }
        // Fallback (or the person asked for the app's pick): an installed Siri voice, else the best one, else the system default.
        return VoiceDecision(voiceIdentifier: VoicePicker.choose(from: candidates, language: language), useAssistiveSettings: false)
    }
}
