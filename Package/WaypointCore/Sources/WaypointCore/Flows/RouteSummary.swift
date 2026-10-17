//
// File:     Flows/RouteSummary.swift
// Module:   WaypointCore
// Owner:    U3 (UI flows)
// Purpose:  Turns an A* route (Router, unchanged) into what a person wants to hear BEFORE walking:
//           "Room 204. About 11 metres, 1 turn, no stairs." and into simple steps
//           (straight 9 m, turn right 1.5 m, arrive) that the mock guidance timeline walks through.
// Turns:    a step starts wherever the walking direction changes by more than
//           RouteFollower.straightThreshold (25 degrees); > turnAroundThreshold is "turn around".
//           Positive bearing = right (Geometry.signedBearing convention).
// Note:     The real route is recomputed from the user's actual position by NavigationController; this
//           summary uses `NavigateFlow.defaultStart` (start of the scan), so it is a preview.
// Status:   DONE, tested in FlowTests.
//
import Foundation
import simd

public struct RouteStep: Equatable, Sendable {
    public var kind: GuidanceInstruction.Kind
    public var distance: Float
    public var hazard: Hazard?
    /// Label of the node this step ends at, if any.
    public var endLabel: String?

    public init(kind: GuidanceInstruction.Kind, distance: Float, hazard: Hazard? = nil, endLabel: String? = nil) {
        self.kind = kind
        self.distance = distance
        self.hazard = hazard
        self.endLabel = endLabel
    }
}

public struct RouteSummary: Equatable, Sendable {

    public let destinationLabel: String
    /// Node ids along the route, start first (used to highlight the route on the plan view).
    public let nodeIds: [UUID]
    /// Walking steps; the last one is always `.arrived` with distance 0.
    public let steps: [RouteStep]

    public var totalDistance: Float { steps.reduce(0) { $0 + $1.distance } }

    public var turnCount: Int {
        steps.filter { $0.kind == .turnLeft || $0.kind == .turnRight || $0.kind == .turnAround }.count
    }

    /// Distinct hazards on the route, in walking order.
    public var hazards: [Hazard] {
        var seen: [Hazard] = []
        for h in steps.compactMap(\.hazard) where !seen.contains(h) { seen.append(h) }
        return seen
    }

    public var hasStairs: Bool { hazards.contains(.stairs) }

    /// "Room 204. About 11 metres, 1 turn, no stairs."
    public var spokenSummary: String {
        let distance = SpokenText.capitalizingFirst(SpokenText.distance(totalDistance))
        let stairs = hasStairs ? "includes stairs" : "no stairs"
        return "\(destinationLabel). \(distance), \(SpokenText.turns(turnCount)), \(stairs)."
    }

    /// "About 11 m · 1 turn · no stairs" for the screen.
    public var shortSummary: String {
        let metres = Int(totalDistance.rounded())
        return "About \(metres) m · \(SpokenText.turns(turnCount)) · \(hasStairs ? "stairs" : "no stairs")"
    }

    /// nil when either node is unknown or unreachable.
    public static func make(map: BuildingMap, from start: UUID, to goal: UUID, allowStairs: Bool = false) -> RouteSummary? {
        let graph = WaypointGraph(map: map)
        guard let route = Router.route(in: graph, from: start, to: goal, allowStairs: allowStairs),
              let destination = route.last else { return nil }

        var steps: [RouteStep] = []
        var previousDirection: SIMD3<Float>?

        for i in 1..<route.count {
            let a = route[i - 1], b = route[i]
            let direction = b.position - a.position
            let edge = graph.edge(between: a.id, b.id)
            let distance = edge?.distance ?? Geometry.horizontalDistance(a.position, b.position)

            var kind: GuidanceInstruction.Kind = .continueStraight
            if let previous = previousDirection {
                let bearing = Geometry.signedBearing(forward: previous, toTarget: direction)
                if abs(bearing) >= RouteFollower.turnAroundThreshold {
                    kind = .turnAround
                } else if abs(bearing) >= RouteFollower.straightThreshold {
                    kind = bearing > 0 ? .turnRight : .turnLeft
                }
            }

            // Merge straight legs into the step before them, unless a hazard needs its own warning.
            if kind == .continueStraight, edge?.hazard == nil, var last = steps.last, last.hazard == nil {
                last.distance += distance
                last.endLabel = b.label
                steps[steps.count - 1] = last
            } else {
                steps.append(RouteStep(kind: kind, distance: distance, hazard: edge?.hazard, endLabel: b.label))
            }

            if Geometry.horizontalDistance(a.position, b.position) > 1e-3 { previousDirection = direction }
        }

        steps.append(RouteStep(kind: .arrived, distance: 0, hazard: nil, endLabel: destination.label))
        return RouteSummary(
            destinationLabel: destination.label ?? "your destination",
            nodeIds: route.map(\.id),
            steps: steps)
    }
}
