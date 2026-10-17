//
// File:     Flows/SpokenText.swift
// Module:   WaypointCore
// Owner:    U3 (UI flows)
// Purpose:  How numbers and instructions are phrased for a listener. Spoken distances are rounded
//           (nobody can use "3.4 metres" while walking) and singular/plural is correct, because
//           VoiceOver users hear every word.
// Status:   DONE, tested in FlowTests.
//
import Foundation

public enum SpokenText {

    /// "less than a metre", "about 1 metre", "about 7 metres", "about 25 metres" (5 m steps above 20 m).
    public static func distance(_ meters: Float) -> String {
        guard meters.isFinite, meters >= 0 else { return "an unknown distance" }
        if meters < 1 { return "less than a metre" }
        let n: Int = meters < 20 ? Int(meters.rounded()) : Int((meters / 5).rounded()) * 5
        return n == 1 ? "about 1 metre" : "about \(n) metres"
    }

    /// Compact visual form for small labels: "10.5 m", "800 m".
    public static func shortDistance(_ meters: Float) -> String {
        guard meters.isFinite, meters >= 0 else { return "–" }
        return meters < 100 ? String(format: "%.1f m", meters) : "\(Int(meters.rounded())) m"
    }

    public static func instruction(_ kind: GuidanceInstruction.Kind) -> String {
        switch kind {
        case .continueStraight: return "Continue straight"
        case .turnLeft: return "Turn left"
        case .turnRight: return "Turn right"
        case .turnAround: return "Turn around"
        case .arrived: return "You have arrived"
        }
    }

    public static func turns(_ count: Int) -> String {
        switch count {
        case 0: return "no turns"
        case 1: return "1 turn"
        default: return "\(count) turns"
        }
    }

    public static func hazard(_ hazard: Hazard) -> String {
        switch hazard {
        case .stairs: return "stairs"
        case .narrow: return "a narrow passage"
        case .doorThreshold: return "a raised door threshold"
        }
    }

    public static func capitalizingFirst(_ s: String) -> String {
        guard let first = s.first else { return s }
        return first.uppercased() + s.dropFirst()
    }
}
