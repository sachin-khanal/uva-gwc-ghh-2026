//
// File:     Guidance/VoicePicker.swift
// Module:   WaypointCore
// Owner:    B (Navigation/Feedback)
// Purpose:  Chooses which text-to-speech voice the app speaks with, as a pure function so the rule is testable without AVFoundation.
//           Rule: the system's SIRI voice for the user's language if the phone has one (best quality first); otherwise the best-quality
//           installed voice for that language; otherwise nil, which means "let the system pick its default".
// Why:      `AVSpeechSynthesisVoice(language:)` returns a generic compact voice, not the Siri voice people recognise. Siri voices appear in
//           `AVSpeechSynthesisVoice.speechVoices()` with "siri" in their identifier when installed (Settings > Accessibility > Spoken Content
//           > Voices, or Siri settings). Apps can not use a voice that is not installed.
// Status:   DONE (logic, unit tested). `Speaker` maps AVSpeechSynthesisVoice -> VoiceCandidate.
//
import Foundation

public struct VoiceCandidate: Equatable, Sendable {
    public var identifier: String
    public var name: String
    /// BCP-47, e.g. "en-US".
    public var language: String
    /// 1 default/compact, 2 enhanced, 3 premium (AVSpeechSynthesisVoiceQuality raw values).
    public var quality: Int

    public init(identifier: String, name: String, language: String, quality: Int) {
        self.identifier = identifier
        self.name = name
        self.language = language
        self.quality = quality
    }

    public var isSiri: Bool { identifier.lowercased().contains("siri") || name.lowercased().contains("siri") }
}

public enum VoicePicker {

    /// - Returns: the identifier to speak with, or nil to use the system default voice.
    public static func choose(from voices: [VoiceCandidate], language: String) -> String? {
        let lang = language.lowercased()
        let base = lang.split(separator: "-").first.map(String.init) ?? lang
        func matches(_ v: VoiceCandidate) -> Bool { v.language.lowercased().hasPrefix(base) }
        func rank(_ v: VoiceCandidate) -> (Int, Int, String) {
            // exact region first (en-US over en-GB), then quality, then a stable tiebreak
            (v.language.lowercased() == lang ? 1 : 0, v.quality, v.identifier)
        }
        let candidates = voices.filter(matches)
        if let siri = candidates.filter(\.isSiri).max(by: { rank($0) < rank($1) }) { return siri.identifier }
        // No Siri voice installed: only override the system default when we have something clearly better than "compact".
        if let best = candidates.max(by: { rank($0) < rank($1) }), best.quality >= 2 { return best.identifier }
        return nil
    }
}
