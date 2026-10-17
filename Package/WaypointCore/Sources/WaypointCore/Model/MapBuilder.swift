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
// Why pure: ARKit (CaptureController) only supplies positions, so the graph-building rules can be
//           unit tested without a phone. See MapBuilderTests.
// Status:   Extension attachment implemented; tested by MapExtensionTests (Mac execution pending).
//           Caller must supply already relocalized MAP-frame positions, in meters.
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

    /// Attach the first new breadcrumb to a nearby existing corridor/junction.
    /// Call only after AR relocalization. A small radius and same-floor check avoid
    /// joining another floor, a tagged room, or a staircase just because it is close.
    /// Failure leaves the map untouched, so the caller can ask the volunteer to move.
    @discardableResult
    public func attachExtension(at position: SIMD3<Float>, maximumDistance: Float = 2) -> Bool {
        guard lastBreadcrumb == nil, SegmentID.isValid(segmentId),
              !map.segmentIds.contains(segmentId),
              position.x.isFinite, position.y.isFinite, position.z.isFinite,
              maximumDistance.isFinite, maximumDistance > 0 else { return false }
        let candidates = map.nodes.filter {
            ($0.kind == .corridor || $0.kind == .junction)
                && abs($0.position.y - position.y) <= 0.75
                && simd_distance($0.position, position) <= maximumDistance
        }
        guard let anchor = candidates.min(by: {
            simd_distance($0.position, position) < simd_distance($1.position, position)
        }) else { return false }
        _ = dropBreadcrumb(at: position, linkedTo: anchor)
        map.version += 1
        return true
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
        return node
    }
}
