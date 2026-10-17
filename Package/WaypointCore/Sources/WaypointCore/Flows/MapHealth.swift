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
        case .duplicateLabels(let labels):
            return "Used more than once: \(labels.joined(separator: ", "))."
        }
    }
}

public enum MapHealth {

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
