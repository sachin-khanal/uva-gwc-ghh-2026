//
// File:     Waypoint/Services/MockGuidanceService.swift
// Owner:    U3 (UI flows)
// Purpose:  Silent, scripted guidance for building and testing the Navigator screens on any iPhone
//           (docs/UI_PLAN.md §2.2). It walks the REAL route from WaypointCore (RouteSummary over Router) at
//           1.2 m/s, so the screens show believable instructions and distances for any map:
//             * 3 s "finding your position", then guiding step by step;
//             * a turn step shows "Turn left/right" for its first 2.5 s, then "Continue straight";
//             * one "caution" obstacle for 2 s at 40% of the route;
//             * arrival at the end.
//           Escort tools: inject a STOP obstacle, force "position lost", force a localization failure, skip.
//           It does not speak (`speaksForItself == false`); NavigatorModel announces changes instead.
// Status:   SCAFFOLD (pure Swift; safe on any iPhone).
//
import Foundation
import WaypointCore

final class MockGuidanceService: GuidanceService {

    var onUpdate: ((GuidanceSnapshot) -> Void)?
    private(set) var snapshot = GuidanceSnapshot.idle { didSet { if snapshot != oldValue { onUpdate?(snapshot) } } }
    let speaksForItself = false
    let supportsPause = true
    let supportsDebugControls = true
    let supportsObstacleInjection = true

    private let tick: TimeInterval = 0.25
    private let speed: Float = 1.2
    private let localizingSeconds: Double = 3
    private var timer: Timer?
    private var steps: [RouteStep] = []
    private var stepIndex = 0
    private var walkedInStep: Float = 0
    private var walkedTotal: Float = 0
    private var totalDistance: Float = 0
    private var elapsed: Double = 0
    private var stepElapsed: Double = 0
    private var cautionUntil: Double?
    private var cautionDone = false
    private var paused = false
    private var stopObstacle = false
    private var lost = false

    deinit { timer?.invalidate() }

    func start(map: BuildingMap, destination: MapNode, from start: MapNode?) {
        stop()
        let label = destination.label ?? "your destination"
        let origin = start ?? NavigateFlow.defaultStart(in: map, excluding: destination.id)
        guard let origin, let summary = RouteSummary.make(map: map, from: origin.id, to: destination.id) else {
            snapshot = GuidanceSnapshot(phase: .failed("There is no route to \(label) in this map."),
                                        destinationLabel: label, rawStatus: "mock: no route")
            return
        }
        steps = summary.steps
        totalDistance = summary.totalDistance
        stepIndex = 0
        walkedInStep = 0
        walkedTotal = 0
        elapsed = 0
        stepElapsed = 0
        cautionUntil = nil
        cautionDone = false
        snapshot = GuidanceSnapshot(phase: .localizing, destinationLabel: label, rawStatus: "mock: localizing")
        timer = Timer.scheduledTimer(withTimeInterval: tick, repeats: true) { [weak self] _ in self?.step() }
    }

    func pause() { paused = true; publish() }
    func resume() { paused = false; publish() }

    func stop() {
        timer?.invalidate()
        timer = nil
        steps = []
        paused = false
        stopObstacle = false
        lost = false
        snapshot = GuidanceSnapshot(destinationLabel: snapshot.destinationLabel, rawStatus: "mock: stopped")
    }

    func injectObstacle(_ on: Bool) { stopObstacle = on; publish() }
    func forceLost(_ on: Bool) { lost = on; publish() }

    func forceFailure() {
        timer?.invalidate()
        timer = nil
        snapshot = GuidanceSnapshot(phase: .failed("I couldn't find your position."),
                                    destinationLabel: snapshot.destinationLabel, rawStatus: "mock: forced failure")
    }

    func skipToArrival() {
        guard !steps.isEmpty else { return }
        stepIndex = steps.count - 1
        walkedTotal = totalDistance
        elapsed = max(elapsed, localizingSeconds)
        publish()
    }

    // MARK: Timeline

    private func step() {
        guard !paused, !lost, !stopObstacle else { publish(); return }
        elapsed += tick
        guard elapsed >= localizingSeconds else { publish(); return }
        guard stepIndex < steps.count, steps[stepIndex].kind != .arrived else { publish(); return }

        stepElapsed += tick
        let move = speed * Float(tick)
        walkedInStep += move
        walkedTotal = min(totalDistance, walkedTotal + move)

        if !cautionDone && walkedTotal >= totalDistance * 0.4 {
            cautionDone = true
            cautionUntil = elapsed + 2
        }
        if let until = cautionUntil, elapsed >= until { cautionUntil = nil }

        if walkedInStep >= steps[stepIndex].distance {
            stepIndex += 1
            walkedInStep = 0
            stepElapsed = 0
        }
        publish()
    }

    private func publish() {
        guard timer != nil || !steps.isEmpty else { return }
        var s = GuidanceSnapshot(destinationLabel: snapshot.destinationLabel)
        s.obstacle = stopObstacle ? .stop : (cautionUntil != nil ? .caution : .clear)
        s.distanceRemaining = max(0, totalDistance - walkedTotal)

        if case .failed = snapshot.phase, timer == nil {
            return // keep the failure on screen until the user acts
        } else if lost {
            s.phase = .lost
        } else if stopObstacle {
            s.phase = .obstacleStop
        } else if elapsed < localizingSeconds {
            s.phase = .localizing
        } else if stepIndex >= steps.count || steps[stepIndex].kind == .arrived {
            s.phase = .arrived
            s.kind = .arrived
            s.distanceRemaining = 0
            timer?.invalidate()
            timer = nil
        } else {
            let current = steps[stepIndex]
            s.phase = .guiding
            let isTurn = current.kind == .turnLeft || current.kind == .turnRight || current.kind == .turnAround
            s.kind = (isTurn && stepElapsed < 2.5) ? current.kind : .continueStraight
            s.distanceToNext = max(0, current.distance - walkedInStep)
        }
        s.rawStatus = "mock: \(s.headline.lowercased())\(paused ? " (paused)" : "")"
        snapshot = s
    }
}
