//
// File:     Scan/CoverageGrid.swift
// Module:   WaypointCore
// Owner:    A (AR/Maps / scan)
// Purpose:  Shows the volunteer WHERE THE SCAN STILL HAS GAPS. The six faces of the scan bounding box (floor, ceiling, four walls) are cut
//           into tiles of ~0.4 m; a tile counts as SCANNED when LiDAR mesh vertices lie within `tolerance` of it. Tiles with no mesh behind
//           them are the "unscanned" polygons the live view draws (yellow fill, dashed white outline: the look of Apple's Measure app).
// Reading it: the box hugs the scanned mesh, so the far end of a hallway you have not walked yet shows up as unscanned: that is the
//           frontier, and it is meant to say "keep going / look up / look at that wall". Coverage % = scanned tiles / all tiles.
// Bounded:  if the box would need more than `maxTiles` tiles the tile size grows, so a huge box cannot stall the phone.
// Frames:   world frame in, world frame out. Faces are defined in the box's own axes (box yaw about +y, see `OrientedBox`).
// Status:   DONE (logic, unit tested). The renderer (LiveScanView) and the vertex sampler (MeshSampler) are app-side, UNVERIFIED ON DEVICE.
//
import Foundation
import simd

public enum BoxFace: Int, CaseIterable, Sendable {
    case floor, ceiling, minX, maxX, minZ, maxZ
}

/// One unscanned tile: 4 world-space corners (counter-clockwise seen from inside the box) and the face's inward normal.
public struct UncoveredTile: Equatable, Sendable {
    public var face: BoxFace
    public var corners: [SIMD3<Float>]
    public var normal: SIMD3<Float>
}

/// A piece of the outline around a region of unscanned tiles.
public struct CoverageSegment: Equatable, Sendable {
    public var a: SIMD3<Float>
    public var b: SIMD3<Float>
    public var normal: SIMD3<Float>
}

public struct CoverageGrid: Sendable {

    public let box: OrientedBox
    public let cellSize: Float
    public let tolerance: Float

    /// Per face: tile counts along its two axes, and the scanned flags (row-major, u fastest).
    private var counts: [BoxFace: (u: Int, v: Int)] = [:]
    private var scanned: [BoxFace: [Bool]] = [:]

    public init(box: OrientedBox, cellSize: Float = 0.4, tolerance: Float = 0.3, maxTiles: Int = 4000) {
        self.box = box
        self.tolerance = tolerance
        var size = max(0.1, cellSize)
        func total(_ s: Float) -> Int {
            BoxFace.allCases.reduce(0) { $0 + Self.axisCounts($1, box.halfExtents, s).u * Self.axisCounts($1, box.halfExtents, s).v }
        }
        var guardrail = 0
        while total(size) > maxTiles, guardrail < 40 { size *= 1.25; guardrail += 1 }
        self.cellSize = size
        for face in BoxFace.allCases {
            let c = Self.axisCounts(face, box.halfExtents, size)
            counts[face] = c
            scanned[face] = Array(repeating: false, count: c.u * c.v)
        }
    }

    public var tileCount: Int { scanned.values.reduce(0) { $0 + $1.count } }
    public var scannedCount: Int { scanned.values.reduce(0) { $0 + $1.filter { $0 }.count } }
    /// 0...1, share of box-face tiles with mesh behind them. 1 for an empty box is never returned (no tiles = 0).
    public var coverage: Float { tileCount == 0 ? 0 : Float(scannedCount) / Float(tileCount) }

    // MARK: Feeding mesh points

    /// Marks tiles scanned by world-space mesh vertices. Call as often as you like; coverage only grows.
    public mutating func add(points: [SIMD3<Float>]) {
        let h = box.halfExtents
        for world in points {
            let p = OrientedBox.rotateY(world - box.center, by: -box.yaw)
            guard abs(p.x) <= h.x + tolerance, abs(p.y) <= h.y + tolerance, abs(p.z) <= h.z + tolerance else { continue }
            if p.y - (-h.y) <= tolerance { mark(.floor, u: p.x + h.x, v: p.z + h.z) }
            if h.y - p.y <= tolerance { mark(.ceiling, u: p.x + h.x, v: p.z + h.z) }
            if p.x - (-h.x) <= tolerance { mark(.minX, u: p.z + h.z, v: p.y + h.y) }
            if h.x - p.x <= tolerance { mark(.maxX, u: p.z + h.z, v: p.y + h.y) }
            if p.z - (-h.z) <= tolerance { mark(.minZ, u: p.x + h.x, v: p.y + h.y) }
            if h.z - p.z <= tolerance { mark(.maxZ, u: p.x + h.x, v: p.y + h.y) }
        }
    }

    private mutating func mark(_ face: BoxFace, u: Float, v: Float) {
        guard let c = counts[face] else { return }
        let iu = min(c.u - 1, max(0, Int(u / cellSize))), iv = min(c.v - 1, max(0, Int(v / cellSize)))
        scanned[face]?[iv * c.u + iu] = true
    }

    // MARK: Output

    /// Every unscanned tile, in world space. `inset` pulls them slightly into the box so they do not z-fight with real surfaces.
    public func uncoveredTiles(inset: Float = 0.01) -> [UncoveredTile] {
        var tiles: [UncoveredTile] = []
        for face in BoxFace.allCases {
            guard let c = counts[face], let flags = scanned[face] else { continue }
            for iv in 0..<c.v { for iu in 0..<c.u where !flags[iv * c.u + iu] {
                let corners = [(iu, iv), (iu + 1, iv), (iu + 1, iv + 1), (iu, iv + 1)].map {
                    world(face, u: Float($0.0) * cellSize, v: Float($0.1) * cellSize, inset: inset)
                }
                tiles.append(UncoveredTile(face: face, corners: corners, normal: worldNormal(face)))
            } }
        }
        return tiles
    }

    /// The outline of the unscanned regions: tile edges between an unscanned tile and a scanned tile (or the face's border).
    public func outline(inset: Float = 0.01) -> [CoverageSegment] {
        var segments: [CoverageSegment] = []
        for face in BoxFace.allCases {
            guard let c = counts[face], let flags = scanned[face] else { continue }
            func open(_ iu: Int, _ iv: Int) -> Bool { iu >= 0 && iv >= 0 && iu < c.u && iv < c.v && !flags[iv * c.u + iu] }
            let n = worldNormal(face)
            func seg(_ u0: Int, _ v0: Int, _ u1: Int, _ v1: Int) {
                segments.append(CoverageSegment(a: world(face, u: Float(u0) * cellSize, v: Float(v0) * cellSize, inset: inset),
                                                b: world(face, u: Float(u1) * cellSize, v: Float(v1) * cellSize, inset: inset), normal: n))
            }
            for iv in 0..<c.v { for iu in 0..<c.u where open(iu, iv) {
                if !open(iu, iv - 1) { seg(iu, iv, iu + 1, iv) }
                if !open(iu, iv + 1) { seg(iu, iv + 1, iu + 1, iv + 1) }
                if !open(iu - 1, iv) { seg(iu, iv, iu, iv + 1) }
                if !open(iu + 1, iv) { seg(iu + 1, iv, iu + 1, iv + 1) }
            } }
        }
        return segments
    }

    /// Splits segments into dashes (the dotted look of Apple's Measure). `dash` and `gap` in metres.
    public static func dashed(_ segments: [CoverageSegment], dash: Float = 0.06, gap: Float = 0.06) -> [CoverageSegment] {
        guard dash > 0, gap >= 0 else { return segments }
        var out: [CoverageSegment] = []
        for s in segments {
            let length = simd_distance(s.a, s.b)
            guard length > 0.0001 else { continue }
            let dir = (s.b - s.a) / length
            var at: Float = 0
            while at < length {
                let end = min(length, at + dash)
                out.append(CoverageSegment(a: s.a + dir * at, b: s.a + dir * end, normal: s.normal))
                at = end + gap
            }
        }
        return out
    }

    // MARK: Geometry

    private static func axisCounts(_ face: BoxFace, _ h: SIMD3<Float>, _ size: Float) -> (u: Int, v: Int) {
        func n(_ half: Float) -> Int { max(1, Int((2 * half / size).rounded(.up))) }
        switch face {
        case .floor, .ceiling: return (n(h.x), n(h.z))
        case .minX, .maxX: return (n(h.z), n(h.y))
        case .minZ, .maxZ: return (n(h.x), n(h.y))
        }
    }

    /// Box-local point of face coordinates (u, v measured in metres from the face's min corner), pulled `inset` metres inside.
    private func world(_ face: BoxFace, u: Float, v: Float, inset: Float) -> SIMD3<Float> {
        let h = box.halfExtents
        let uu = min(u, 2 * dimension(face).u), vv = min(v, 2 * dimension(face).v) // last tile may overhang; clamp to the face
        var p: SIMD3<Float>
        switch face {
        case .floor: p = SIMD3(uu - h.x, -h.y + inset, vv - h.z)
        case .ceiling: p = SIMD3(uu - h.x, h.y - inset, vv - h.z)
        case .minX: p = SIMD3(-h.x + inset, vv - h.y, uu - h.z)
        case .maxX: p = SIMD3(h.x - inset, vv - h.y, uu - h.z)
        case .minZ: p = SIMD3(uu - h.x, vv - h.y, -h.z + inset)
        case .maxZ: p = SIMD3(uu - h.x, vv - h.y, h.z - inset)
        }
        return box.center + OrientedBox.rotateY(p, by: box.yaw)
    }

    private func dimension(_ face: BoxFace) -> (u: Float, v: Float) {
        let h = box.halfExtents
        switch face {
        case .floor, .ceiling: return (h.x, h.z)
        case .minX, .maxX: return (h.z, h.y)
        case .minZ, .maxZ: return (h.x, h.y)
        }
    }

    /// Inward-pointing normal of a face, in world space.
    private func worldNormal(_ face: BoxFace) -> SIMD3<Float> {
        let local: SIMD3<Float>
        switch face {
        case .floor: local = [0, 1, 0]
        case .ceiling: local = [0, -1, 0]
        case .minX: local = [1, 0, 0]
        case .maxX: local = [-1, 0, 0]
        case .minZ: local = [0, 0, 1]
        case .maxZ: local = [0, 0, -1]
        }
        return OrientedBox.rotateY(local, by: box.yaw)
    }
}

/// Resuming a paused scan far from where it was paused would join the two spots with a straight "walkable" edge through whatever lies
/// between them (possibly a wall). So resume is only allowed near the pause point.
public enum ResumeGuard {
    public static let maxDistanceMeters: Float = 2.0

    public static func canResume(pausedAt: SIMD3<Float>?, now: SIMD3<Float>?) -> Bool {
        guard let pausedAt, let now else { return true } // nothing to compare: do not trap the user in pause
        return Geometry.horizontalDistance(pausedAt, now) <= maxDistanceMeters
    }

    public static func message(distance: Float) -> String {
        "You are \(Int(distance.rounded())) meters from where you paused. Walk back to that spot, then resume."
    }
}
