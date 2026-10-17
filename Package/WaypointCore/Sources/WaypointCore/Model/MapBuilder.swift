//
// File:     Model/MapBuilder.swift
// Module:   WaypointCore
// Owner:    A (AR/Maps)
// Purpose:  Turns a stream of camera positions into a waypoint graph while the volunteer walks.
//           * `observe(position:)`   called every AR frame; drops a corridor breadcrumb node
//                                    whenever the camera moved `breadcrumbSpacing` meters from
//                                    the previous breadcrumb, and links them with an edge.
//           * `addPOI(...)`          called when the volunteer taps Door/Stairs/Room/...; adds a
//                                    labelled leaf node attached to the most recent breadcrumb.
//           * LOOP CLOSURE: a new breadcrumb is also linked to any OLD node the volunteer has walked
//                                    back to (within `revisitRadius`). Without this the graph is a
//                                    chain, not a graph: in a building with a central core (Rice Hall)
//                                    the two ends of a loop end up metres apart in space but dozens of
//                                    nodes apart in the graph, so A* sends the user all the way round
//                                    the long way. Reported on device 2026-10-17.
//           Safety: we only connect nodes the volunteer PHYSICALLY STOOD AT, so the link is walkable
//                                    by construction. We never infer an edge from proximity alone -
//                                    two corridors either side of a thin wall are close in space and
//                                    joining them would route a blind user into a wall.
// Why pure: ARKit (CaptureController) only supplies positions, so the graph-building rules can be
//           unit tested without a phone. See MapBuilderTests.
//
import Foundation
import simd

public final class MapBuilder {

    /// The map being built. Read it to save or display progress.
    public private(set) var map: BuildingMap

    /// Meters of walking between automatic breadcrumb nodes (Architecture.md section 4.1).
    public var breadcrumbSpacing: Float

    private let segmentId: String
    private let deviceName: String
    /// Most recent breadcrumb. POIs attach here; the next breadcrumb continues from here.
    private var lastBreadcrumb: MapNode?

    /// How close a new breadcrumb must be to an older one to count as "the volunteer walked back here".
    /// Walking back along the same corridor puts you within half the breadcrumb spacing (0.75 m at the
    /// default 1.5 m) of an old node, so 1.0 m catches a real revisit while staying well under the
    /// width of a corridor plus a wall - we must never join two corridors through the wall between them.
    public var revisitRadius: Float = 1.0
    /// How many breadcrumbs back to ignore when looking for a revisit. The previous few are always
    /// within a stride or two and are already linked by the chain; linking them again proves nothing.
    public var minChainSeparation: Int = 4
    /// Breadcrumb ids in the order they were dropped (chain order), for the separation test above.
    private var chain: [UUID] = []

    public init(
        map: BuildingMap,
        segmentId: String = "seg1",
        deviceName: String,
        breadcrumbSpacing: Float = 1.5
    ) {
        self.map = map
        self.segmentId = segmentId
        self.deviceName = deviceName
        self.breadcrumbSpacing = breadcrumbSpacing
    }

    /// Feed the camera's current map-frame position. Returns the new node if one was dropped.
    @discardableResult
    public func observe(position: SIMD3<Float>) -> MapNode? {
        guard let last = lastBreadcrumb else {
            return dropBreadcrumb(at: position, linkedTo: nil)
        }
        if simd_distance(last.position, position) >= breadcrumbSpacing {
            return dropBreadcrumb(at: position, linkedTo: last)
        }
        return nil
    }

    /// Adds a tagged point of interest attached to the last breadcrumb (or standalone if the
    /// volunteer tags before walking anywhere). It does NOT become the new breadcrumb anchor, so
    /// the corridor chain stays continuous.
    @discardableResult
    public func addPOI(kind: NodeKind, label: String?, position: SIMD3<Float>) -> MapNode {
        let node = MapNode(
            kind: kind, label: label, position: position,
            segmentId: segmentId, createdBy: deviceName)
        map.nodes.append(node)
        if let anchor = lastBreadcrumb {
            let hazard: Hazard? = (kind == .stairs) ? .stairs : nil
            map.edges.append(MapEdge(
                from: anchor.id, to: node.id,
                distance: simd_distance(anchor.position, position), hazard: hazard))
        }
        return node
    }

    // MARK: Private

    private func dropBreadcrumb(at position: SIMD3<Float>, linkedTo previous: MapNode?) -> MapNode {
        let node = MapNode(
            kind: .corridor, label: nil, position: position,
            segmentId: segmentId, createdBy: deviceName)
        map.nodes.append(node)
        if let previous {
            map.edges.append(MapEdge(
                from: previous.id, to: node.id,
                distance: simd_distance(previous.position, position)))
        }
        lastBreadcrumb = node
        chain.append(node.id)
        closeLoop(at: node)
        return node
    }

    /// Links `node` to any earlier breadcrumb the volunteer has just walked back to. See the loop
    /// closure note in the file header.
    private func closeLoop(at node: MapNode) {
        // Everything except the last few links of the chain is a candidate.
        let recent = Set(chain.suffix(minChainSeparation + 1))
        for candidate in map.nodes where candidate.kind == .corridor && !recent.contains(candidate.id) {
            let distance = simd_distance(candidate.position, node.position)
            guard distance <= revisitRadius else { continue }
            guard !map.edges.contains(where: { $0.connects(candidate.id, node.id) }) else { continue }
            map.edges.append(MapEdge(from: candidate.id, to: node.id, distance: distance))
        }
    }
}
