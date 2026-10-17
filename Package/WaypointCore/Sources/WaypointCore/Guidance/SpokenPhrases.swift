//
// File:     Guidance/SpokenPhrases.swift
// Module:   WaypointCore
// Owner:    B (Navigation/Feedback) with U4 (wording review)
// Purpose:  Every sentence the app speaks about obstacles, distances and upcoming turns, in one place so wording can be reviewed and tested without a phone.
// Style:    short, concrete, say what to DO first ("Stop."), then WHAT ("You are about to walk into a trash can.") and WHERE.
//           Distances use STEPS up close (about 0.7 m each, what a blind walker can feel) and metres further away.
//           Never claim more than we know: low-confidence object names are "possibly a ...", unknown things are "an obstacle".
//
import Foundation

public enum DistanceSpeech {
    /// "right in front of you", "about 2 steps", "about 4 meters".
    public static func phrase(meters: Float) -> String {
        if meters < 0.5 { return "right in front of you" }
        if meters <= 2.1 {
            let steps = max(1, Int((meters / 0.7).rounded()))
            return "about \(steps) \(steps == 1 ? "step" : "steps")"
        }
        let m = Int(meters.rounded())
        return "about \(m) meters"
    }

    /// For countdowns: "3 meters", "1 meter".
    public static func meters(_ meters: Float) -> String {
        let m = max(1, Int(meters.rounded()))
        return "\(m) \(m == 1 ? "meter" : "meters")"
    }
}

public enum ObstacleSpeech {

    static func noun(_ kind: ObstacleKind) -> String {
        switch kind {
        case .wall: return "a wall"
        case .door: return "a door"
        case .window: return "a window or glass"
        case .table: return "a table"
        case .chair: return "a chair"
        case .person: return "a person"
        case .trashCan: return "a trash can"
        case .plant: return "a plant"
        case .furniture: return "a piece of furniture"
        case .stairs: return "stairs"
        case .unknown: return "an obstacle"
        }
    }

    private static func sideText(_ side: Side) -> String {
        switch side {
        case .left: return "on your left"
        case .right: return "on your right"
        case .ahead: return "ahead"
        }
    }

    /// Reports below this are hedged with "possibly".
    private static let hedgeBelow: Float = 0.6

    private static func hedged(_ r: ObstacleReport) -> String {
        let n = noun(r.kind)
        return (r.confidence < hedgeBelow && r.kind != .unknown) ? "possibly \(n)" : n
    }

    /// STOP level: the user is about to hit something. `report == nil` keeps the plain legacy phrase.
    public static func stop(_ r: ObstacleReport?) -> String {
        guard let r else { return "Stop. Obstacle ahead." }
        let n = hedged(r)
        // Not sure what it is: say so plainly instead of "...walk into possibly a...".
        if r.confidence < hedgeBelow, r.kind != .unknown, r.side == .ahead { return "Stop. Possibly \(noun(r.kind)) directly ahead." }
        switch (r.kind, r.side) {
        case (.wall, .ahead): return "Stop. You are heading toward a wall."
        case (.person, .ahead): return "Stop. \(capitalized(n)) is directly ahead."
        case (.stairs, _): return "Stop. Stairs directly ahead."
        case (.unknown, .ahead): return "Stop. Obstacle directly ahead."
        case (_, .ahead): return "Stop. You are about to walk into \(n)."
        default: return "Stop. \(capitalized(n)) very close \(sideText(r.side))."
        }
    }

    /// CAUTION level: something is near but not yet at stop distance.
    /// The thing ahead is on the route and has to be opened or climbed, not avoided. Caution, not
    /// alarm, and it says what to DO - a blind user standing outside a closed door needs to know to
    /// open it, not that something is in the way (device report 2026-10-17).
    public static func wayThrough(_ r: ObstacleReport?, targetLabel: String?) -> String {
        let place = targetLabel.flatMap { l -> String? in
            let t = l.trimmingCharacters(in: .whitespaces)
            return t.isEmpty ? nil : t
        }
        switch r?.kind {
        case .stairs:
            return "Stairs ahead. These are on your route - take them carefully."
        case .door:
            let which = place.map { "The door to \($0) is" } ?? "There is a door"
            return "\(which) right ahead. You will need to open it to get in."
        default:
            let which = place.map { "to \($0) " } ?? ""
            return "The way \(which)is right ahead."
        }
    }

    public static func caution(_ r: ObstacleReport?) -> String {
        guard let r else { return "Obstacle ahead." }
        return "Careful. \(capitalized(hedged(r))) \(sideText(r.side)), \(DistanceSpeech.phrase(meters: r.distanceMeters))."
    }

    private static func capitalized(_ s: String) -> String { s.prefix(1).uppercased() + s.dropFirst() }
}

/// Turn cues with a real angle: "Turn right 30 degrees." rather than a bare "Turn right."
/// A blind user cannot see how far to turn, and "turn right" alone is as easily 15 degrees as 90
/// (device report 2026-10-17).
public enum TurnSpeech {

    /// Angles are rounded to this many degrees. Finer than this is false precision - neither the
    /// heading estimate nor a person turning on the spot is accurate to one degree.
    public static let stepDegrees: Float = 5

    /// Bands, as specified by the team after walking Rice Hall (2026-10-17):
    ///   < 5     nothing to do, you are on course
    ///   5-45    "Slightly right 20 degrees."   - a correction while walking
    ///   45-60   "Right 50 degrees."            - a real but odd-sized turn
    ///   60-120  "Right."                       - the ordinary corner; the angle adds nothing
    ///   120-150 "Right 130 degrees."           - sharper than a corner
    ///   >= 150  "Turn around."
    public static let onCourseDegrees: Float = 5
    public static let slightMaxDegrees: Float = 45
    public static let squareMinDegrees: Float = 60
    public static let squareMaxDegrees: Float = 120
    public static let turnAroundDegrees: Float = 150

    public static func rounded(degrees: Float) -> Int {
        let step = stepDegrees
        return max(Int(step), Int((degrees / step).rounded() * step))
    }

    /// The words for a turn of `bearingRadians` (positive = right), independent of WHY we are turning.
    public static func phrase(bearingRadians: Float) -> String {
        // The epsilon keeps the band edges honest: 5 degrees converted to radians and back is
        // 4.9999995, which would otherwise read as "on course".
        let degrees = abs(bearingRadians) * 180 / .pi + 1e-3
        let side = bearingRadians > 0 ? "right" : "left"
        switch degrees {
        case ..<onCourseDegrees:
            return "Continue straight."
        case ..<slightMaxDegrees:
            return "Slightly \(side) \(rounded(degrees: degrees)) degrees."
        case ..<squareMinDegrees:
            return "\(side.capitalized) \(rounded(degrees: degrees)) degrees."
        case ..<squareMaxDegrees:
            // A square corner. Saying "90 degrees" adds nothing a person can act on.
            return "\(side.capitalized)."
        case ..<turnAroundDegrees:
            return "\(side.capitalized) \(rounded(degrees: degrees)) degrees."
        default:
            return "Turn around."
        }
    }

    /// nil when the cue is not a turn (arrival is announced elsewhere).
    public static func text(kind: GuidanceInstruction.Kind, bearingRadians: Float) -> String? {
        switch kind {
        case .arrived: return nil
        case .continueStraight: return "Continue straight."
        case .turnAround: return "Turn around."
        case .turnLeft, .turnRight:
            let words = phrase(bearingRadians: bearingRadians)
            // The planner has decided this IS a turn, so never answer "continue straight" just because
            // the measured bearing is small. Use the side the planner chose.
            guard words == "Continue straight." else { return words }
            let side = (kind == .turnRight) ? "right" : "left"
            return "Slightly \(side) \(rounded(degrees: onCourseDegrees)) degrees."
        }
    }

    /// Same turn, but say WHY when the reason is not simply the route - a user who is turning to avoid
    /// a wall deserves to know that is what is happening (team request 2026-10-17).
    public static func text(kind: GuidanceInstruction.Kind, bearingRadians: Float,
                            reason: TurnReason) -> String? {
        guard let base = text(kind: kind, bearingRadians: bearingRadians) else { return nil }
        guard let because = reason.clause else { return base }
        return "\(base) \(because)"
    }
}

/// Why a turn is being asked for. `.route` is the normal case and says nothing extra.
public enum TurnReason: Equatable, Sendable {
    case route
    case avoiding(ObstacleKind)
    case backOnRoute

    var clause: String? {
        switch self {
        case .route: return nil
        case .backOnRoute: return "Getting you back on the route."
        case .avoiding(let kind):
            let noun = ObstacleSpeech.noun(kind)
            return "There is \(noun) ahead."
        }
    }
}

public enum ManeuverSpeech {

    /// Advance warning, e.g. "In 5 meters, turn right."
    public static func warning(_ m: Maneuver) -> String {
        let d = DistanceSpeech.meters(m.distanceMeters)
        switch m.kind {
        case .turnLeft: return "In \(d), turn left."
        case .turnRight: return "In \(d), turn right."
        case .stairs: return "In \(d), stairs."
        case .arrive: return "In \(d), you will arrive\(m.label.map { " at \($0)" } ?? "")."
        }
    }

    /// Spoken once at the start of a route: "Walk about 12 meters, then turn right."
    /// ONE move, not an itinerary. The "..., then turn left" tail was dropped (2026-10-17): the
    /// countdown already announces the turn at 10, 5 and 2 metres, and a blind user walking needs the
    /// move they are making now - not a preview of the one after it, spoken in the same breath.
    public static func briefing(distanceToFirstManeuver m: Maneuver?) -> String? {
        guard let m else { return nil }
        let d = DistanceSpeech.meters(m.distanceMeters)
        switch m.kind {
        case .arrive: return "Walk straight about \(d)\(m.label.map { " to \($0)" } ?? "")."
        case .turnLeft, .turnRight, .stairs: return "Walk straight about \(d)."
        }
    }

    public static func landmark(label: String, side: Side) -> String {
        "\(label) on your \(side == .left ? "left" : "right")."
    }
}

/// What the user hears when they reach the destination.
///
/// Why this exists: at the destination the thing the depth sensor sees IS the door or room we were
/// walking to, so the obstacle wording ("Stop. You are about to walk into a door.") was both alarming
/// and wrong about what had happened - it hid the arrival (reported on device 2026-10-17).
/// The phrasing is driven by the destination node's `NodeKind`, so it works for any kind of
/// destination, not just doors.
public enum ArrivalSpeech {

    /// A door/stairs/elevator is a thing standing in front of you and worth naming; a room or a
    /// corridor node is just the place itself, which `label` already names.
    static func feature(_ kind: NodeKind?) -> String? {
        switch kind {
        case .door: return "door"
        case .stairs: return "stairs"
        case .elevator: return "elevator"
        case .room, .corridor, .junction, nil: return nil
        }
    }

    public static func text(kind: NodeKind?, label: String?) -> String {
        let name = label?.trimmingCharacters(in: .whitespaces)
        let place = (name?.isEmpty == false) ? name : nil

        switch (feature(kind), place) {
        case let (feature?, place?):
            // "You have arrived at Room 204. The door is right in front of you."
            let verb = (kind == .stairs) ? "are" : "is"
            return "You have arrived at \(place). The \(feature) \(verb) right in front of you."
        case let (feature?, nil):
            return "You have arrived at the \(feature)."
        case let (nil, place?):
            return "You have arrived at \(place)."
        case (nil, nil):
            return "You have arrived."
        }
    }
}
