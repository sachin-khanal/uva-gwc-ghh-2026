//
// File:     Routing/RoutePlanner.swift
// Module:   WaypointCore
// Owner:    B (Navigation/Feedback)
// Purpose:  Remembers the shortest route between places (`RouteMemory`) and plans routes that stay
//           LIVE-ADAPTABLE: the memory is only a default. A remembered route is used only if it is
//           still valid for the current map, stairs preference and live blockages; otherwise the
//           route is recomputed with A* (`Router`). Sign reads can re-anchor where the user is.
// Design:   * Memory key = (from, to, allowStairs). Entry = node ids + cost + map fingerprint.
//           * Memory is never trusted blindly: every lookup re-validates nodes, edges, hazards,
//             blockages. A stale/invalid entry is dropped and recomputed.
//           * Blockages are temporary (TTL) so a person standing in a corridor does not
//             permanently remove it from the map. Routes computed around a blockage are NOT
//             stored, so memory always holds the undisturbed shortest path.
//           * `RouteMemory` is Codable so the app can persist it (e.g. next to the map JSON).
// Threading: not thread-safe; use from one actor (NavigationController is main-actor).
// Status:   DONE (logic, unit tested). TODO(B): wire into NavigationController, feed blockages from
//           ObstacleClassifier and signs from SignReader; persist memory with MapStore.
//
import Foundation
import simd

/// An undirected edge identified by its two node ids (order does not matter).
public struct EdgeKey: Hashable, Sendable {
    public let a: UUID
    public let b: UUID
    public init(_ x: UUID, _ y: UUID) {
        if x.uuidString <= y.uuidString { a = x; b = y } else { a = y; b = x }
    }
}

/// A route memory entry.
public struct RememberedRoute: Codable, Equatable, Sendable {
    public var nodeIds: [UUID]
    public var cost: Float
    public var fingerprint: UInt64
    public var uses: Int
    public var lastUsed: Date
}

/// Persistable cache of shortest routes. Plain value type; `RoutePlanner` owns the policy.
public struct RouteMemory: Codable, Equatable, Sendable {
    public var entries: [String: RememberedRoute] = [:]
    public init() {}

    static func key(_ from: UUID, _ to: UUID, _ allowStairs: Bool) -> String {
        "\(from.uuidString)>\(to.uuidString)>\(allowStairs ? "s" : "n")"
    }
}

/// Where a planned route came from.
public enum RouteSource: Sendable, Equatable {
    case memory      // served from memory (re-validated)
    case computed    // A*, default (no blockages involved) - stored in memory
    case detour      // A* around a live blockage - NOT stored
}

public struct PlannedRoute: Sendable {
    /// The route to WALK: the raw graph path passed through `RouteSimplifier` (the graph is a trail of the volunteer's footsteps).
    public let nodes: [MapNode]
    /// The raw A* path, every consecutive pair joined by an edge. This is what memory stores and re-validates.
    public let path: [MapNode]
    public let source: RouteSource
    /// Length of `path` along its edges (metres).
    public var totalDistance: Float
}

/// What a sign read tells us about where the user is.
public enum SignVerdict: Sendable, Equatable {
    case consistent(nodeId: UUID)          // sign is at a map node near the user: no change
    case relocate(nodeId: UUID)            // sign belongs to a node far from where we think we are
    case ambiguous                         // several nodes carry that label
    case unknown                           // no node has that label
}

public final class RoutePlanner {

    /// A sign within this horizontal distance of the user's believed position agrees with the map.
    public static let signAgreementRadius: Float = 5
    public static let defaultBlockageTTL: TimeInterval = 600

    public private(set) var graph: WaypointGraph
    public private(set) var memory: RouteMemory
    private var blockedUntil: [EdgeKey: Date] = [:]
    private var fingerprint: UInt64

    public init(graph: WaypointGraph, memory: RouteMemory = RouteMemory()) {
        self.graph = graph
        self.memory = memory
        self.fingerprint = Self.fingerprint(of: graph.map)
    }

    /// Swap in a new/updated map (e.g. after a scan extension). Old memory entries die lazily:
    /// their fingerprint no longer matches so they are recomputed.
    public func update(graph: WaypointGraph) {
        self.graph = graph
        self.fingerprint = Self.fingerprint(of: graph.map)
    }

    // MARK: Planning

    public func plan(from: UUID, to: UUID, allowStairs: Bool = false, now: Date = Date()) -> PlannedRoute? {
        let blocked = activeBlockages(now: now)
        let key = RouteMemory.key(from, to, allowStairs)

        if var hit = memory.entries[key] {
            if let path = validated(hit, allowStairs: allowStairs, blocked: blocked) {
                hit.uses += 1
                hit.lastUsed = now
                memory.entries[key] = hit
                return PlannedRoute(nodes: Router.simplified(path, in: graph), path: path, source: .memory, totalDistance: hit.cost)
            }
            // Invalid now. If it is only the blockage that broke it, keep it for later;
            // if the map changed under it, drop it.
            if hit.fingerprint != fingerprint || validated(hit, allowStairs: allowStairs, blocked: []) == nil {
                memory.entries[key] = nil
            }
        }

        guard let path = Router.route(in: graph, from: from, to: to, allowStairs: allowStairs, avoiding: blocked, simplify: false) else {
            return nil
        }
        let cost = length(of: path)
        let walk = Router.simplified(path, in: graph)
        if blocked.isEmpty {
            memory.entries[key] = RememberedRoute(
                nodeIds: path.map(\.id), cost: cost, fingerprint: fingerprint, uses: 1, lastUsed: now)
            return PlannedRoute(nodes: walk, path: path, source: .computed, totalDistance: cost)
        }
        return PlannedRoute(nodes: walk, path: path, source: .detour, totalDistance: cost)
    }

    /// Plan from where the user STANDS: tries the few nearest nodes as a start and keeps the cheapest "walk to it + route from it"
    /// (on a loop corridor the nearest node can be on the wrong branch). Each candidate goes through the memory.
    public func plan(fromPosition position: SIMD3<Float>, to goal: UUID, allowStairs: Bool = false,
                     candidates: Int = Router.startCandidates, now: Date = Date()) -> PlannedRoute? {
        var best: (route: PlannedRoute, cost: Float)?
        for start in graph.nearestNodes(to: position, limit: candidates) {
            guard let route = plan(from: start.id, to: goal, allowStairs: allowStairs, now: now) else { continue }
            let cost = Geometry.horizontalDistance(position, start.position) + Router.length(of: route.nodes)
            if best == nil || cost < best!.cost { best = (route, cost) }
        }
        return best?.route
    }

    /// Precompute routes between every pair of labelled places so the first request is instant.
    @discardableResult
    public func warm(allowStairs: Bool = false, now: Date = Date()) -> Int {
        let places = graph.map.nodes.filter { ($0.label?.isEmpty == false) }
        var count = 0
        for a in places { for b in places where a.id != b.id {
            if plan(from: a.id, to: b.id, allowStairs: allowStairs, now: now) != nil { count += 1 }
        } }
        return count
    }

    // MARK: Live adaptation

    /// Something (obstacle, closed door, sign saying "closed") blocks the walk between two nodes.
    public func reportBlocked(_ a: UUID, _ b: UUID, ttl: TimeInterval = RoutePlanner.defaultBlockageTTL, now: Date = Date()) {
        blockedUntil[EdgeKey(a, b)] = now.addingTimeInterval(ttl)
    }

    public func clearBlockage(_ a: UUID, _ b: UUID) { blockedUntil[EdgeKey(a, b)] = nil }
    public func clearAllBlockages() { blockedUntil.removeAll() }

    /// Block the next leg of `route` (the one the user is on) and replan from where they are.
    public func detour(around blocked: (UUID, UUID), from current: UUID, to goal: UUID,
                       allowStairs: Bool = false, ttl: TimeInterval = RoutePlanner.defaultBlockageTTL,
                       now: Date = Date()) -> PlannedRoute? {
        reportBlocked(blocked.0, blocked.1, ttl: ttl, now: now)
        return plan(from: current, to: goal, allowStairs: allowStairs, now: now)
    }

    /// Compare text read from a sign with where the map says the user is.
    public func interpretSign(_ text: String, userPosition: SIMD3<Float>) -> SignVerdict {
        let q = WaypointGraph.normalize(text)
        guard !q.isEmpty else { return .unknown }
        let matches = graph.map.nodes.filter { n in
            guard let label = n.label else { return false }
            let l = WaypointGraph.normalize(label)
            return l == q || l == "room" + q
        }
        guard let first = matches.first else { return .unknown }
        if matches.count > 1 {
            // Several nodes share the label: only trust it if exactly one is near the user.
            let near = matches.filter { Geometry.horizontalDistance($0.position, userPosition) < Self.signAgreementRadius }
            return near.count == 1 ? .consistent(nodeId: near[0].id) : .ambiguous
        }
        let d = Geometry.horizontalDistance(first.position, userPosition)
        return d < Self.signAgreementRadius ? .consistent(nodeId: first.id) : .relocate(nodeId: first.id)
    }

    // MARK: Helpers

    private func activeBlockages(now: Date) -> Set<EdgeKey> {
        blockedUntil = blockedUntil.filter { $0.value > now }
        return Set(blockedUntil.keys)
    }

    private func validated(_ entry: RememberedRoute, allowStairs: Bool, blocked: Set<EdgeKey>) -> [MapNode]? {
        guard entry.fingerprint == fingerprint, !entry.nodeIds.isEmpty else { return nil }
        let nodes = entry.nodeIds.compactMap { graph.node(id: $0) }
        guard nodes.count == entry.nodeIds.count else { return nil }
        for (u, v) in zip(nodes, nodes.dropFirst()) {
            guard let edge = graph.edge(between: u.id, v.id) else { return nil }
            if blocked.contains(EdgeKey(u.id, v.id)) { return nil }
            if !allowStairs && edge.hazard == .stairs { return nil }
        }
        return nodes
    }

    private func length(of nodes: [MapNode]) -> Float {
        zip(nodes, nodes.dropFirst()).reduce(0) { $0 + (graph.edge(between: $1.0.id, $1.1.id)?.distance ?? 0) }
    }

    /// Stable (FNV-1a) hash of the walkable structure; `Hasher` is randomised per launch so it
    /// cannot be persisted.
    static func fingerprint(of map: BuildingMap) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        func mix(_ s: String) { for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 } }
        for n in map.nodes.sorted(by: { $0.id.uuidString < $1.id.uuidString }) { mix(n.id.uuidString) }
        for e in map.edges.sorted(by: { ($0.from.uuidString, $0.to.uuidString) < ($1.from.uuidString, $1.to.uuidString) }) {
            mix(e.from.uuidString); mix(e.to.uuidString)
            mix(String(e.distance.bitPattern)); mix(e.hazard?.rawValue ?? "-")
        }
        return h
    }
}

// MARK: - Live-adaptation helpers (pure, tested)

extension RoutePlanner {
    /// Horizontal distance from `position` to the nearest point of the route polyline (metres).
    /// Used to notice that the user has wandered off the route.
    public static func offRouteDistance(position: SIMD3<Float>, route: [MapNode]) -> Float {
        guard let first = route.first else { return .infinity }
        guard route.count > 1 else { return Geometry.horizontalDistance(position, first.position) }
        var best = Float.infinity
        for (a, b) in zip(route, route.dropFirst()) {
            let ax = a.position.x, az = a.position.z
            let dx = b.position.x - ax, dz = b.position.z - az
            let len2 = dx * dx + dz * dz
            let t = len2 > 0 ? max(0, min(1, ((position.x - ax) * dx + (position.z - az) * dz) / len2)) : 0
            let px = ax + t * dx, pz = az + t * dz
            best = min(best, hypot(position.x - px, position.z - pz))
        }
        return best
    }
}

/// Fires once when an obstacle has stayed at `.stop` level for `seconds`: a person walking past
/// must not re-route the user, but a closed door or a parked cart should.
public struct BlockageTracker: Sendable {
    public let seconds: TimeInterval
    private var since: TimeInterval?
    private var fired = false
    public init(seconds: TimeInterval = 4) { self.seconds = seconds }

    public mutating func update(level: ObstacleLevel, time: TimeInterval) -> Bool {
        guard level == .stop else { since = nil; fired = false; return false }
        if since == nil { since = time }
        if !fired, time - (since ?? time) >= seconds { fired = true; return true }
        return false
    }
    public mutating func reset() { since = nil; fired = false }
}
