//
// File:     Flows/MapHealth.swift
// Module:   WaypointCore
// Owner:    U3 (UI flows)
// Purpose:  Checks shown on the Scanner "Review" screen before a map is shared: problems a sighted
//           volunteer can still fix but a blind user would only discover mid-route.
//           This is ADVICE, not validation: `MapBundle.validate()` (unchanged) remains the security gate.
// Status:   DONE, tested in FlowTests.
//
import Foundation

public enum MapWarning: Equatable, Sendable {
    /// Fewer than 2 nodes: nothing to walk.
    case tooSmall
    /// No labelled place a blind user could pick.
    case noDestinations
    /// Tagged rooms/doors/stairs/elevators without a label.
    case unlabeled(count: Int)
    /// The graph falls apart into several pieces; some places are unreachable.
    case disconnected(parts: Int)
    /// The same label is used more than once (the user can't tell them apart).
    case duplicateLabels([String])
    /// The walk passes back through a place it has already been, but the two visits were never joined.
    /// The map then has only one way round, so a route can take the long way round a corridor loop.
    /// A straight corridor has no loops either, and that is fine - this fires only on a REVISIT.
    case unclosedLoop(count: Int)

    public var message: String {
        switch self {
        case .tooSmall:
            return "The map is too small. Walk further while scanning."
        case .noDestinations:
            return "No labelled places yet, so there is nowhere to navigate to."
        case .unlabeled(let count):
            return count == 1 ? "1 tagged place has no label." : "\(count) tagged places have no label."
        case .disconnected(let parts):
            return "The map is split into \(parts) parts. Some places can't be reached."
        case .unclosedLoop(let count):
            return "The scan passes back through \(count == 1 ? "a place" : "\(count) places") it has already been without joining up, so routes may take the long way round. Rescan that stretch walking slowly over your own path."
        case .duplicateLabels(let labels):
            return "Used more than once: \(labels.joined(separator: ", "))."
        }
    }
}

public enum MapHealth {

    /// Two breadcrumbs this close are the same spot in the building.
    static let revisitRadius: Float = 1.5
    /// ...but only if they are far apart in the WALK, otherwise they are simply consecutive steps.
    static let revisitSeparation = 10

    /// How many times the walk comes back to a place it has already been without an edge joining the
    /// two visits. A straight corridor scores 0; a loop walked once and never closed scores at least 1.
    static func unclosedRevisits(_ map: BuildingMap) -> Int {
        let trail = map.nodes.filter { $0.kind == .corridor }
        guard trail.count > revisitSeparation else { return 0 }
        var joined = Set<String>()
        for edge in map.edges {
            let ids = [edge.from.uuidString, edge.to.uuidString].sorted()
            joined.insert(ids[0] + ids[1])
        }
        var count = 0
        for i in 0..<(trail.count - revisitSeparation) {
            for j in (i + revisitSeparation)..<trail.count
            where Geometry.horizontalDistance(trail[i].position, trail[j].position) <= revisitRadius {
                let ids = [trail[i].id.uuidString, trail[j].id.uuidString].sorted()
                if !joined.contains(ids[0] + ids[1]) { count += 1 }
                break // one report per revisited spot
            }
        }
        return count
    }

    public static func check(_ map: BuildingMap) -> [MapWarning] {
        var warnings: [MapWarning] = []
        if map.nodes.count < 2 { warnings.append(.tooSmall) }
        if map.destinations.isEmpty { warnings.append(.noDestinations) }

        let unlabeled = map.nodes.filter { node in
            node.kind != .corridor && node.kind != .junction && (node.label ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        }.count
        if unlabeled > 0 { warnings.append(.unlabeled(count: unlabeled)) }

        let parts = componentCount(map)
        if parts > 1 { warnings.append(.disconnected(parts: parts)) }

        let unclosed = unclosedRevisits(map)
        if unclosed > 0 { warnings.append(.unclosedLoop(count: unclosed)) }

        var firstSpelling: [String: String] = [:]
        var counts: [String: Int] = [:]
        for label in map.nodes.compactMap(\.label) {
            let key = label.trimmingCharacters(in: .whitespaces).lowercased()
            guard !key.isEmpty else { continue }
            counts[key, default: 0] += 1
            if firstSpelling[key] == nil { firstSpelling[key] = label }
        }
        let duplicates = counts.filter { $0.value > 1 }.keys.compactMap { firstSpelling[$0] }.sorted()
        if !duplicates.isEmpty { warnings.append(.duplicateLabels(duplicates)) }

        return warnings
    }

    /// Number of connected pieces of the graph (0 for an empty map). Edges to unknown nodes are ignored.
    public static func componentCount(_ map: BuildingMap) -> Int {
        let ids = Set(map.nodes.map(\.id))
        var adjacency: [UUID: [UUID]] = [:]
        for e in map.edges where ids.contains(e.from) && ids.contains(e.to) {
            adjacency[e.from, default: []].append(e.to)
            adjacency[e.to, default: []].append(e.from)
        }
        var seen: Set<UUID> = []
        var parts = 0
        for node in map.nodes where !seen.contains(node.id) {
            parts += 1
            var stack = [node.id]
            seen.insert(node.id)
            while let current = stack.popLast() {
                for next in adjacency[current] ?? [] where !seen.contains(next) {
                    seen.insert(next)
                    stack.append(next)
                }
            }
        }
        return parts
    }
}
