//
// File:     Waypoint/Services/MockScanService.swift
// Owner:    U3 (UI flows)
// Purpose:  Fake scanner so the Scanner screens can be built, demoed and tested without LiDAR or ARKit
//           (docs/UI_PLAN.md §2.2). Deterministic timeline (0.5 s ticks):
//             0-1 s   tracking "starting"; quality notAvailable until 3 s
//             3-8 s   quality limited; 8-15 s extending; mapped from 15 s
//             6-8 s   tracking limited ("Moving too fast") to exercise the warning banner
//             10 s    suggests the label "Room 204" (stand-in for SignReader)
//           The fake walker drops a breadcrumb every 2 s, 1.5 m apart: 6 steps "north" (-z), then "east" (+x).
//           Tags are placed 1 m to the walker's right and linked to the latest breadcrumb, so `finish()` produces
//           a VALID, routable map (it passes MapBundle.validate: edge lengths equal node distances). It has no
//           ARWorldMap, so it can be used with Demo data / Simulated walk, not real relocalization.
// Status:   SCAFFOLD (pure Swift; safe on any iPhone).
//
import ARKit
import simd
import WaypointCore

final class MockScanService: ScanService {

    var onUpdate: ((ScanSnapshot) -> Void)?
    private(set) var snapshot = ScanSnapshot() { didSet { if snapshot != oldValue { onUpdate?(snapshot) } } }
    let isMock = true
    var arSession: ARSession? { nil }
    var scanBox: OrientedBox? { nil }

    private let store: MapStore
    private let deviceName: String
    private var timer: Timer?
    private var ticks = 0
    private var isPaused = false
    private var suggestionOffered = false

    private var map = BuildingMap(name: "")
    private var lastBreadcrumb: MapNode?
    private var walkerPosition = SIMD3<Float>(0, 0, 0)
    private var walkerForward = SIMD3<Float>(0, 0, -1)
    private var walked: Float = 0
    private let tick: TimeInterval = 0.5
    private let stepLength: Float = 1.5
    private let segmentId = "seg1"

    init(store: MapStore, deviceName: String) {
        self.store = store
        self.deviceName = deviceName
    }

    deinit { timer?.invalidate() }

    func start(mapName: String) {
        cancel()
        map = BuildingMap(name: mapName + " · demo")
        walkerPosition = .zero
        walkerForward = SIMD3<Float>(0, 0, -1)
        walked = 0
        ticks = 0
        isPaused = false
        suggestionOffered = false
        lastBreadcrumb = nil
        dropBreadcrumb()
        snapshot = ScanSnapshot(isRunning: true, nodeCount: map.nodes.count)
        timer = Timer.scheduledTimer(withTimeInterval: tick, repeats: true) { [weak self] _ in self?.step() }
    }

    func pause() { isPaused = true }
    func resume() { isPaused = false }

    func tag(kind: NodeKind, label: String?) {
        guard snapshot.isRunning else { return }
        let right = SIMD3<Float>(-walkerForward.z, 0, walkerForward.x)
        let node = MapNode(kind: kind, label: label, position: walkerPosition + right,
                           segmentId: segmentId, createdBy: deviceName)
        map.nodes.append(node)
        if let crumb = lastBreadcrumb {
            map.edges.append(MapEdge(from: crumb.id, to: node.id, distance: simd_distance(crumb.position, node.position),
                                     hazard: kind == .stairs ? .stairs : nil))
        }
        snapshot.tags.append(ScanTag(id: node.id, kind: kind, label: label))
        snapshot.nodeCount = map.nodes.count
        if let label, label == snapshot.suggestion { snapshot.suggestion = nil }
    }

    func dismissSuggestion() { snapshot.suggestion = nil }

    func adjustBox(by delta: Float) {
        snapshot.boxMargin = min(2, max(0, snapshot.boxMargin + delta))
    }

    func finish(completion: @escaping (Result<BuildingMap, Error>) -> Void) {
        timer?.invalidate()
        timer = nil
        let result = map
        do {
            try store.save(result)
            snapshot.isRunning = false
            // A short delay so the "Saving" state is visible, like the real save.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { completion(.success(result)) }
        } catch {
            snapshot.errorMessage = "Save failed: \(error.localizedDescription)"
            completion(.failure(error))
        }
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
        snapshot.isRunning = false
    }

    // MARK: Timeline

    private func step() {
        guard !isPaused else { return }
        ticks += 1
        let t = Double(ticks) * tick
        var s = snapshot

        if t < 1 { s.tracking = .starting }
        else if t >= 6 && t < 8 { s.tracking = .limited("Moving too fast") }
        else { s.tracking = .normal }

        if t < 3 { s.quality = .notAvailable }
        else if t < 8 { s.quality = .limited }
        else if t < 15 { s.quality = .extending }
        else { s.quality = .mapped }

        if s.tracking.isNormal {
            s.triangleCount += 1_800
            if ticks % 4 == 0 { walk() }
        }
        s.boxSize = SIMD3<Float>(min(6, 2 + Float(t) * 0.1), 2.6, max(2, walked + 1))
        s.nodeCount = map.nodes.count
        if t >= 10 && !suggestionOffered {
            suggestionOffered = true
            s.suggestion = "Room 204"
        }
        snapshot = s
    }

    private func walk() {
        if map.nodes.filter({ $0.kind == .corridor }).count == 6 {
            walkerForward = SIMD3<Float>(1, 0, 0) // the corridor turns right
        }
        walkerPosition += walkerForward * stepLength
        walked += stepLength
        dropBreadcrumb()
    }

    private func dropBreadcrumb() {
        let node = MapNode(kind: .corridor, position: walkerPosition, segmentId: segmentId, createdBy: deviceName)
        map.nodes.append(node)
        if let previous = lastBreadcrumb {
            map.edges.append(MapEdge(from: previous.id, to: node.id, distance: simd_distance(previous.position, node.position)))
        }
        lastBreadcrumb = node
    }
}
