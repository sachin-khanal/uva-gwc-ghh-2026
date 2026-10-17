//
// File:     Waypoint/UI/Navigator/NavigatorModel.swift
// Owner:    U3 (UI flows)
// Purpose:  View model for the new Navigator workflow (docs/UI_PLAN.md §7). Holds the NavigateFlow state,
//           the chosen map/destination and route preview (RouteSummary), owns the GuidanceService while a
//           route runs, and decides what is SAID:
//             * mock service (silent)      -> announces every phase/instruction change via Announcer;
//             * live / simulated services  -> SpeechGuide already speaks, so only "repeat" is announced
//                                             (one voice at a time, UI_PLAN §7 principle 6).
//           Safety: stopping is explicit; after arrival the engine is stopped a few seconds later so the
//           arrival sentence is not cut off.
// Threading: main thread only.
// Status:   SCAFFOLD, UNVERIFIED ON DEVICE.
//
import SwiftUI
import WaypointCore

final class NavigatorModel: ObservableObject {

    @Published private(set) var flow = NavigateFlow(mapCount: 0)
    @Published private(set) var selectedMapId: UUID?
    @Published private(set) var destination: MapNode?
    @Published private(set) var summary: RouteSummary?
    @Published private(set) var guidance = GuidanceSnapshot.idle
    @Published private(set) var isPaused = false
    @Published private(set) var mode: ServiceMode = .mock

    private(set) var service: GuidanceService?
    /// Where the current route starts (used for "guide me back").
    private var startNode: MapNode?
    /// False until `configure` ran; the flow view renders nothing before that, so no screen (and no spoken
    /// prompt) appears with the wrong number of maps.
    @Published private(set) var isConfigured = false

    // MARK: Setup

    func configure(maps: [BuildingMap]) {
        guard !isConfigured else { return }
        mode = ServiceMode.current
        flow = NavigateFlow(mapCount: maps.count)

        let defaults = UserDefaults.standard
        if let pending = defaults.string(forKey: UIPrefs.pendingMapId),
           let id = UUID(uuidString: pending), maps.contains(where: { $0.id == id }) {
            defaults.removeObject(forKey: UIPrefs.pendingMapId)
            selectedMapId = id
            flow.chooseMap()
        } else if maps.count == 1 {
            selectedMapId = maps[0].id
        }
        isConfigured = true
    }

    func selectedMap(in maps: [BuildingMap]) -> BuildingMap? {
        maps.first { $0.id == selectedMapId }
    }

    var isActive: Bool { flow.step == .active }
    var speaksForItself: Bool { service?.speaksForItself ?? false }
    var supportsPause: Bool { service?.supportsPause ?? false }
    var supportsObstacleInjection: Bool { service?.supportsObstacleInjection ?? false }
    var supportsDebugControls: Bool { service?.supportsDebugControls ?? false }
    var canRouteBack: Bool { startNode != nil && mode != .simulated }

    // MARK: Choosing

    func chooseMap(_ map: BuildingMap) {
        selectedMapId = map.id
        flow.chooseMap()
    }

    func chooseDestination(_ node: MapNode, in map: BuildingMap) {
        destination = node
        startNode = NavigateFlow.defaultStart(in: map, excluding: node.id)
        summary = startNode.flatMap { RouteSummary.make(map: map, from: $0.id, to: node.id) }
        Recents.add(node.id, mapId: map.id)
        flow.chooseDestination()
    }

    /// Route preview for a destination row (from the start of the map).
    func previewSummary(to node: MapNode, in map: BuildingMap) -> RouteSummary? {
        guard let start = NavigateFlow.defaultStart(in: map, excluding: node.id) else { return nil }
        return RouteSummary.make(map: map, from: start.id, to: node.id)
    }

    // MARK: Running

    func start(map: BuildingMap, store: MapStore) {
        guard let destination else { return }
        stopService()
        mode = ServiceMode.current
        let service = ServiceFactory.makeGuidanceService(mode: mode, store: store)
        self.service = service
        service.onUpdate = { [weak self] snapshot in self?.receive(snapshot) }
        isPaused = false
        guidance = GuidanceSnapshot(phase: .localizing, destinationLabel: displayName(destination))
        flow.start()
        UIApplication.shared.isIdleTimerDisabled = true
        Announcer.stop()
        if !service.speaksForItself {
            Announcer.say("Starting guidance to \(displayName(destination)). Finding your position. Slowly turn left and right.", interrupt: true)
        }
        service.start(map: map, destination: destination, from: startNode)
    }

    /// Retry after a localization failure.
    func retry(map: BuildingMap, store: MapStore) {
        flow.stop()
        flow.chooseDestination()
        start(map: map, store: store)
    }

    func stop() {
        stopService()
        flow.stop()
        Announcer.say("Guidance stopped.", interrupt: true)
    }

    func repeatInstruction() {
        Announcer.say(guidance.spokenText, interrupt: true)
    }

    func announceDistanceRemaining() {
        if let remaining = guidance.distanceRemaining {
            Announcer.say("\(SpokenText.capitalizingFirst(SpokenText.distance(remaining))) to \(guidance.destinationLabel).", interrupt: true)
        } else if let next = guidance.distanceToNext {
            Announcer.say("\(SpokenText.capitalizingFirst(SpokenText.distance(next))) to the next point.", interrupt: true)
        } else {
            Announcer.say("Distance not known yet.", interrupt: true)
        }
    }

    func togglePause() {
        guard let service, service.supportsPause else {
            repeatInstruction()
            return
        }
        isPaused.toggle()
        if isPaused { service.pause() } else { service.resume() }
        Announcer.say(isPaused ? "Guidance paused." : "Guidance resumed.", interrupt: true)
    }

    func routeBack(map: BuildingMap) {
        guard let from = destination, let to = startNode else { return }
        destination = to
        startNode = from
        summary = RouteSummary.make(map: map, from: from.id, to: to.id)
        flow.routeBack()
    }

    func newDestination() {
        stopService()
        flow.newDestination()
    }

    /// Back / escape gesture. Returns false when Navigate mode should be left.
    func back() -> Bool {
        var f = flow
        let handled = f.back()
        flow = f
        return handled
    }

    func leave() {
        stopService()
        Announcer.stop()
    }

    func displayName(_ node: MapNode) -> String {
        node.label ?? "the start point"
    }

    // Escort tools
    func injectObstacle(_ on: Bool) { service?.injectObstacle(on) }
    func forceLost(_ on: Bool) { service?.forceLost(on) }
    func forceFailure() { service?.forceFailure() }
    func skipToArrival() { service?.skipToArrival() }

    // MARK: Private

    private func receive(_ new: GuidanceSnapshot) {
        let old = guidance
        guidance = new
        if !(service?.speaksForItself ?? true) { announceChange(from: old, to: new) }

        if new.phase == .arrived && flow.step == .active {
            flow.arrive()
            UIApplication.shared.isIdleTimerDisabled = false
            // Let the arrival sentence finish before the live engine is stopped (its stop() cuts speech).
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                guard let self, self.flow.step == .arrived else { return }
                self.stopService()
            }
        }
    }

    private func announceChange(from old: GuidanceSnapshot, to new: GuidanceSnapshot) {
        if new.phase != old.phase {
            switch new.phase {
            case .guiding:
                let prefix = old.phase == .localizing ? "Position found. " : ""
                Announcer.say(prefix + new.spokenText, interrupt: old.phase == .lost || old.phase == .obstacleStop)
            case .lost, .obstacleStop:
                Announcer.say(new.spokenText, interrupt: true)
            case .arrived, .failed:
                Announcer.say(new.spokenText, interrupt: true)
            case .idle, .localizing:
                break
            }
            return
        }
        guard new.phase == .guiding else { return }
        if new.kind != old.kind {
            Announcer.say(new.spokenText)
        } else if new.obstacle == .caution && old.obstacle != .caution {
            Announcer.say("Obstacle ahead.", interrupt: true)
        }
    }

    private func stopService() {
        service?.onUpdate = nil
        service?.stop()
        service = nil
        isPaused = false
        UIApplication.shared.isIdleTimerDisabled = false
    }
}

/// Recently chosen destinations per map (most recent first, max 3). Per-viewer convenience only.
enum Recents {
    static func ids(mapId: UUID) -> [UUID] {
        (UserDefaults.standard.stringArray(forKey: UIPrefs.recentsKey(mapId: mapId)) ?? []).compactMap(UUID.init(uuidString:))
    }

    static func add(_ id: UUID, mapId: UUID) {
        var list = ids(mapId: mapId).filter { $0 != id }
        list.insert(id, at: 0)
        UserDefaults.standard.set(list.prefix(3).map(\.uuidString), forKey: UIPrefs.recentsKey(mapId: mapId))
    }
}
