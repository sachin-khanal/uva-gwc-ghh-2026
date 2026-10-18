//
// File:     Guidance/VoiceOptions.swift
// Module:   WaypointCore
// Owner:    B (Navigation/Feedback)
// Purpose:  Pure logic behind the "Voice" settings: which installed voices to offer (and how to name them), and how fast to speak.
// Why:      The guidance voice is the one thing a blind user hears all day; it has to be choosable and adjustable WITHOUT a screen reader in
//           the way. When VoiceOver is running none of this applies - the person's own VoiceOver voice and rate are used (`VoiceSelection`).
// Rate:     a FACTOR of the system's default speech rate (1.0 = default), clamped, so the setting means the same thing on every iOS version.
// Status:   DONE (logic, unit tested). The settings screen and the previews are UNVERIFIED ON DEVICE.
//
import Foundation

public struct VoiceRow: Equatable, Identifiable, Sendable {
    public var id: String { identifier }
    public var identifier: String
    /// "Nicky"
    public var title: String
    /// "Siri, Compact, en-US"
    public var detail: String
    public var quality: Int
    public var isSiri: Bool
}

public enum VoiceCatalog {

    public static func qualityName(_ quality: Int) -> String {
        switch quality {
        case 3...: return "Premium"
        case 2: return "Enhanced"
        default: return "Compact"
        }
    }

    /// Installed voices for the person's language, best first: higher quality, then Siri voices, then the exact region (en-US before en-GB), then name.
    public static func rows(from voices: [VoiceCandidate], language: String) -> [VoiceRow] {
        let lang = language.lowercased()
        let base = lang.split(separator: "-").first.map(String.init) ?? lang
        return voices
            .filter { $0.language.lowercased().hasPrefix(base) }
            .sorted { a, b in
                if a.quality != b.quality { return a.quality > b.quality }
                if a.isSiri != b.isSiri { return a.isSiri }
                let aExact = a.language.lowercased() == lang, bExact = b.language.lowercased() == lang
                if aExact != bExact { return aExact }
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
            .map { v in
                VoiceRow(identifier: v.identifier, title: v.name,
                         detail: ([v.isSiri ? "Siri" : nil, qualityName(v.quality), v.language] as [String?]).compactMap { $0 }.joined(separator: ", "),
                         quality: v.quality, isSiri: v.isSiri)
            }
    }

    /// Only compact voices installed: the settings screen then says where to download a better one.
    public static func suggestsBetterVoice(_ rows: [VoiceRow]) -> Bool { !rows.contains { $0.quality >= 2 } }
}

public enum SpeechRate {
    public static let defaultFactor: Double = 1.0
    public static let range: ClosedRange<Double> = 0.75...1.6

    public static func clamp(_ factor: Double) -> Double {
        guard factor.isFinite else { return defaultFactor }
        return min(max(factor, range.lowerBound), range.upperBound)
    }

    /// The value for `AVSpeechUtterance.rate` (pass the system's default / minimum / maximum rate in).
    public static func utteranceRate(factor: Double, defaultRate: Float, minimum: Float, maximum: Float) -> Float {
        min(max(defaultRate * Float(clamp(factor)), minimum), maximum)
    }
}
