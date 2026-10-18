//
// File:     Vision/ObstacleKind.swift
// Module:   WaypointCore
// Owner:    C (Vision) with B (phrasing) - requirement from U1: "object-type classification ('stop, you are about to head into a trash can')"
// Purpose:  The vocabulary for WHAT is in the way and WHERE, plus the mapping from the raw labels the phone produces to that vocabulary:
//             * ARKit mesh classification (wall, floor, ceiling, table, seat, window, door, none)  - reliable for room structure, says "none" for
//               everything else (a trash can is "none" to ARKit);
//             * Apple Vision image classification of the pixels where the obstacle is (labels like "trash can", "chair", "person") - covers
//               the objects ARKit cannot name, with lower confidence.
//           `ObstacleLabelMapper` turns either into an `ObstacleKind`; `ObstacleSpeech` (Guidance/ObstacleSpeech.swift) turns a report into words.
// Honesty rule: a label is only used when its confidence is high enough; otherwise the kind is `.unknown` and we say "obstacle", never a wrong
//           object name. Low-confidence object names are spoken as "possibly a ...".
// Tuning:   the keyword lists below are matched against whole words; extend them from the real vocabulary printed by `make selftest-e2e`
//           (`vision.classify.vocabulary`) and add a test for every new keyword.
//
import Foundation

/// Horizontal position of something relative to the way the user is facing.
public enum Side: String, Equatable, Sendable {
    case left, ahead, right
}

public enum ObstacleKind: String, Equatable, CaseIterable, Sendable {
    case wall, door, window, table, chair, person, trashCan, plant, stairs, furniture
    case unknown
}

public struct ObstacleReport: Equatable, Sendable {
    public var kind: ObstacleKind
    public var side: Side
    public var distanceMeters: Float
    /// 0...1. Mesh classification of structure is ~0.9; image classification of objects is whatever Vision reports.
    public var confidence: Float

    public init(kind: ObstacleKind, side: Side = .ahead, distanceMeters: Float, confidence: Float = 1) {
        self.kind = kind
        self.side = side
        self.distanceMeters = distanceMeters
        self.confidence = confidence
    }
}

public enum ObstacleLabelMapper {

    /// ARKit `ARMeshClassification` case name -> obstacle. Floor/ceiling/none are not obstacles (nil).
    public static func kind(fromMeshClass name: String) -> ObstacleKind? {
        switch name.lowercased() {
        case "wall": return .wall
        case "door": return .door
        case "window": return .window
        case "table": return .table
        case "seat": return .chair
        default: return nil
        }
    }

    /// Ordered: the first rule whose keyword appears as a WHOLE WORD in the label wins, so list more specific kinds first.
    private static let rules: [(ObstacleKind, Set<String>)] = [
        (.trashCan, ["trash", "garbage", "waste", "rubbish", "dustbin", "wastebasket", "bin", "litter"]),
        (.person, ["person", "people", "adult", "child", "man", "woman", "human", "crowd", "pedestrian"]),
        (.stairs, ["stairs", "staircase", "stairway", "steps", "escalator"]),
        (.chair, ["chair", "chairs", "stool", "bench", "sofa", "couch", "armchair", "wheelchair"]),
        (.table, ["table", "desk", "counter"]),
        (.furniture, ["cabinet", "shelf", "shelves", "bookcase", "bookshelf", "dresser", "wardrobe", "refrigerator", "bed", "cart"]),
        (.door, ["door", "doorway"]),
        (.window, ["window", "glass"]),
        (.plant, ["plant", "potted", "flower", "tree", "houseplant", "vase"]),
        (.wall, ["wall", "brick"]),
    ]

    /// Best obstacle kind for a list of (label, confidence) pairs from image classification, or nil if nothing relevant is confident enough.
    public static func kind(fromImageLabels labels: [(label: String, confidence: Float)], minConfidence: Float = 0.30) -> (kind: ObstacleKind, confidence: Float)? {
        var best: (ObstacleKind, Float)?
        for (label, confidence) in labels where confidence >= minConfidence {
            let words = Set(label.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init))
            for (kind, keywords) in rules where !words.isDisjoint(with: keywords) {
                if best == nil || confidence > best!.1 { best = (kind, confidence) }
                break
            }
        }
        return best.map { (kind: $0.0, confidence: $0.1) }
    }
}

/// Which depth samples count as OBSTACLES, so the floor under the user's feet and the ceiling are not mistaken for something in the way.
/// Heights are relative to the phone. `assumedPhoneHeight` is how high the phone is held above the floor (chest height).
public enum ObstacleBand {
    /// How high the phone is held above the floor (chest height). ONE definition, because the obstacle
    /// band and the floor-drop check (`FloorAhead`) must agree about where the floor is - if they
    /// disagree, one of them is measuring against a floor the other does not believe in.
    public static let assumedPhoneHeight: Float = 1.3

    public static func contains(
        pointY: Float, cameraY: Float,
        assumedPhoneHeight: Float = ObstacleBand.assumedPhoneHeight,
        minAboveFloor: Float = 0.15, maxAbovePhone: Float = 0.3
    ) -> Bool {
        let floorY = cameraY - assumedPhoneHeight
        return pointY >= floorY + minAboveFloor && pointY <= cameraY + maxAbovePhone
    }
}

/// Is the thing the depth sensor sees the thing the route is taking us THROUGH?
///
/// A door in front of the room you asked for is not an obstacle to avoid - it is how you get in, and
/// you have to open it. Saying "Stop. You are about to walk into a door." leaves a blind user stranded
/// outside their destination (reported on device 2026-10-17). Same for the stairs you were routed to.
/// Anything else - a wall, a chair, a person - is still an obstacle and still gets the full warning.
public enum RouteFeature {

    public static func isWayThrough(obstacle: ObstacleKind?, target: NodeKind?) -> Bool {
        guard let obstacle, let target else { return false }
        switch (obstacle, target) {
        // The door of the room you are going to, or a door you were routed to directly.
        case (.door, .room), (.door, .door): return true
        // The stairs you were routed to (a hazard, but an intended one).
        case (.stairs, .stairs): return true
        default: return false
        }
    }
}
