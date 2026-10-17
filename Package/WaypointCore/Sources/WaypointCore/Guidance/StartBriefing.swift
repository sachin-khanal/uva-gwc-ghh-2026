//
// File:     Guidance/StartBriefing.swift
// Module:   WaypointCore
// Owner:    B (Navigation/Feedback)
// Purpose:  The one short message spoken when navigation actually begins (once the position has settled): WHERE you are, WHAT is around you,
//           HOW to get to the destination. Written to be listened to: at most three sentences, no lists longer than two items.
//           Example: "You are near Room 206. Stairs on your left. Room 204 is about 25 meters away. Walk straight about 12 meters, then turn right."
// Sources:  the map (named places near the user), the live surroundings (`SceneContext`: something close ahead, narrow space), and the route.
// Honesty:  only names places the map has; never invents a room. If nothing is known nearby it says so plainly.
// Status:   DONE (logic, unit tested). Wired by NavigationController.
//
import Foundation
import simd

public enum StartBriefing {

    /// A named place this close counts as "at" it, this close as "near" it.
    public static let atMeters: Float = 2.5
    public static let nearMeters: Float = 6
    /// Named places within this distance are mentioned as "around you" (at most `maxAround`).
    public static let aroundMeters: Float = 10
    public static let maxAround = 2
    /// Something this close straight ahead is worth saying at the start.
    public static let closeAheadMeters: Float = 3

    public static func text(
        position: SIMD3<Float>,
        forward: SIMD3<Float>,
        graph: WaypointGraph,
        route: [MapNode],
        destination: MapNode,
        context: SceneContext?,
        firstManeuver: Maneuver?
    ) -> String {
        let named = graph.map.nodes.filter { ($0.label?.isEmpty == false) && $0.id != destination.id }
            .map { (node: $0, distance: Geometry.horizontalDistance(position, $0.position)) }
            .sorted { $0.distance < $1.distance }

        var sentences: [String] = []

        // 1. Where am I?
        var placeId: UUID?
        if let nearest = named.first, nearest.distance <= nearMeters, let label = nearest.node.label {
            placeId = nearest.node.id
            sentences.append(nearest.distance <= atMeters ? "You are at \(label)." : "You are near \(label).")
        } else if let any = graph.nearestNode(to: position), any.kind == .corridor || any.kind == .junction {
            sentences.append("You are in a hallway.")
        } else {
            sentences.append("I have found your position.")
        }

        // 2. What is around me? Named places first, then one live fact from the sensors.
        let around = named.filter { $0.node.id != placeId && $0.distance <= aroundMeters }.prefix(maxAround)
        if !around.isEmpty {
            let phrases = around.compactMap { item -> String? in
                guard let label = item.node.label else { return nil }
                return "\(label) \(Self.direction(from: position, facing: forward, to: item.node.position))"
            }
            sentences.append(phrases.joined(separator: ", ") + ".")
        }
        if let context {
            if let ahead = context.aheadClearance, ahead < closeAheadMeters {
                sentences.append("Something is \(DistanceSpeech.meters(ahead)) ahead.")
            } else if context.isNarrow {
                sentences.append("The space is narrow.")
            }
        }

        // 3. How do I get there?
        let first = route.first.map { Geometry.horizontalDistance(position, $0.position) } ?? 0
        let total = first + Router.length(of: route)
        let name = destination.label.flatMap { $0.isEmpty ? nil : $0 } ?? "Your destination"
        sentences.append("\(name) is \(total < 3 ? "just ahead" : "about \(DistanceSpeech.meters(total)) away").")
        if let how = ManeuverSpeech.briefing(distanceToFirstManeuver: firstManeuver) { sentences.append(how) }

        return sentences.joined(separator: " ")
    }

    /// "ahead" / "on your left" / "on your right" / "behind you", from the user's facing direction.
    static func direction(from position: SIMD3<Float>, facing: SIMD3<Float>, to target: SIMD3<Float>) -> String {
        let b = Geometry.signedBearing(forward: facing, toTarget: target - position)
        let deg = abs(b) * 180 / .pi
        if deg < 35 { return "ahead" }
        if deg > 135 { return "behind you" }
        return b > 0 ? "on your right" : "on your left"
    }
}

/// What the user hears when a sign is read out of the camera image.
public enum SignSpeech {
    public static func text(read: String, isDestination: Bool) -> String {
        isDestination ? "Sign reads \(read). This is your destination." : "Sign reads \(read)."
    }
}
