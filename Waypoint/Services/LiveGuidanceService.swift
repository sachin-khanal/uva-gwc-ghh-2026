//
// File:     Waypoint/Services/LiveGuidanceService.swift
// Owner:    U3 (UI flows) - mapping to be reviewed by U2 (owner of NavigationController)
// Purpose:  Connects the new Navigator screens to the EXISTING `NavigationController`, observe-only
//           (docs/UI_PLAN.md rule R3). It calls only existing API (start, startSimulation, stop,
//           simulatedObstacle) and reads statusText / instructionText / obstacleLevel. The phase is derived by
//           `GuidanceSnapshot.derive` in WaypointCore, which FlowTests pin to NavigationController's wording.
//           NavigationController is not modified; the classic NavigatorView keeps its own instance.
// Speech:   NavigationController's SpeechGuide speaks every instruction, so `speaksForItself = true` and
//           the UI does not repeat it (except when the user asks: "repeat").
// Limits:   no pause, no distance-remaining, no forced failure (requested from U2 in UI_PLAN §11).
// Status:   SCAFFOLD, UNVERIFIED ON DEVICE.
//
import Combine
import Foundation
import WaypointCore

final class LiveGuidanceService: GuidanceService {

    var onUpdate: ((GuidanceSnapshot) -> Void)?
    private(set) var snapshot = GuidanceSnapshot.idle { didSet { if snapshot != oldValue { onUpdate?(snapshot) } } }
    let speaksForItself = true
    let supportsPause = false
    let supportsDebugControls = false
    var supportsObstacleInjection: Bool { simulate }

    private let controller = NavigationController()
    private let store: MapStore
    private let simulate: Bool
    private var destinationLabel = ""
    private var cancellable: AnyCancellable?

    init(store: MapStore, simulate: Bool) {
        self.store = store
        self.simulate = simulate
        cancellable = controller.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
    }

    deinit { controller.stop() }

    func start(map: BuildingMap, destination: MapNode, from start: MapNode?) {
        destinationLabel = destination.label ?? "your destination"
        if simulate {
            controller.startSimulation(map: map, destination: destination)
        } else {
            controller.start(map: map, destination: destination, store: store)
        }
        refresh()
    }

    func pause() {}
    func resume() {}

    func stop() {
        controller.stop()
        refresh()
    }

    func injectObstacle(_ on: Bool) {
        guard simulate else { return }
        controller.simulatedObstacle = on
    }

    func forceLost(_ on: Bool) {}
    func forceFailure() {}
    func skipToArrival() {}

    private func refresh() {
        snapshot = GuidanceSnapshot.derive(
            status: controller.statusText,
            instruction: controller.instructionText,
            obstacle: controller.obstacleLevel,
            destinationLabel: destinationLabel)
    }
}
