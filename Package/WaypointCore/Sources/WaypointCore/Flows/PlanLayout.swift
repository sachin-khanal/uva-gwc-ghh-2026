//
// File:     Flows/PlanLayout.swift
// Module:   WaypointCore
// Owner:    U3 (UI flows)
// Purpose:  Projects map nodes onto a 2D drawing area for the plan view (Review screen, docs/UI_PLAN.md §5.2).
//           Top-down view, "north-up" = map -z points up the screen (the direction the volunteer first
//           walked, since walking forward from the scan start decreases z). Uniform scale, centred, with
//           padding. Uses its own point type so the package stays free of UI frameworks.
// Status:   DONE, tested in FlowTests.
//
import Foundation

public struct PlanPoint: Equatable, Sendable {
    public var x: Float
    public var y: Float

    public init(x: Float, y: Float) {
        self.x = x
        self.y = y
    }
}

public enum PlanLayout {

    /// Screen position of every node, keyed by node id. Empty if there is nothing to draw or no room.
    /// A span smaller than 1 m is treated as 1 m so a single node or a straight line is centred, not stretched.
    public static func project(_ nodes: [MapNode], width: Float, height: Float, padding: Float) -> [UUID: PlanPoint] {
        guard let first = nodes.first, width > 2 * padding, height > 2 * padding else { return [:] }

        var minX = first.position.x, maxX = first.position.x
        var minZ = first.position.z, maxZ = first.position.z
        for n in nodes {
            minX = min(minX, n.position.x); maxX = max(maxX, n.position.x)
            minZ = min(minZ, n.position.z); maxZ = max(maxZ, n.position.z)
        }

        let availableW = width - 2 * padding
        let availableH = height - 2 * padding
        let scale = min(availableW / max(maxX - minX, 1), availableH / max(maxZ - minZ, 1))
        let offsetX = padding + (availableW - (maxX - minX) * scale) / 2
        let offsetY = padding + (availableH - (maxZ - minZ) * scale) / 2

        var result: [UUID: PlanPoint] = [:]
        for n in nodes {
            result[n.id] = PlanPoint(
                x: offsetX + (n.position.x - minX) * scale,
                y: offsetY + (n.position.z - minZ) * scale)
        }
        return result
    }
}
