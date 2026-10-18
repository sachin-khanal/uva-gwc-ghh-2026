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
// Update 2026-10-18 (branch final-ui-changes):
//             * Before the search starts, `preNavigationBriefing` is spoken (hold the phone upright at chest level;
//               press and hold the screen to stop) and the search begins only once it has finished (`isBriefing`).
//             * Finding the position never gives up on its own: a positioning failure is announced with
//               `strugglingMessage` and the search restarts (LocalizingView repeats the message every 15 s).
//               Only "there is no route" ends the attempt: it is said, and the user is back at the places list.
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
    /// True while the pre-navigation instructions are being spoken, before the search starts.
    @Published private(set) var isBriefing = false

    /// The map and store of the route being run, kept so the search can restart without the user.
    private var activeMap: BuildingMap?
    private var activeStore: MapStore?
    /// Bumped whenever a run is stopped or restarted, so a delayed step from an older run does nothing.
    private var runToken = 0

    /// How to stop, worded for how the user operates the screen.
    static var stopInstruction: String {
        Announcer.isVoiceOverRunning
            ? "To stop navigation, double tap the screen, then confirm."
            : "To stop navigation, press and hold the screen."
    }

    /// Spoken after Start guidance, before the search for the user's position begins.
    static var preNavigationBriefing: String {
        "Before we start: hold the phone upright at chest level, with the back camera facing forward. \(stopInstruction)"
    }

    /// Spoken when the position has not been found for a while (every 15 s, see LocalizingView), and after a
    /// positioning failure before the search restarts.
    static var strugglingMessage: String {
        "I'm having trouble finding your starting position. Move slightly, stand still, then slowly turn left and right. \(stopInstruction)"
    }

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
    /// Live navigation controller, when there is one. Debug overlay only (NavDebugView).
    var debugController: NavigationController? { service?.debugController }
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

    /// Start guidance: speak the pre-navigation instructions, then (once they have been said) start looking for
    /// the user's position. Holding the screen during the instructions stops everything, as at any other time.
    func start(map: BuildingMap, store: MapStore) {
        guard let destination else { return }
        stopService()
        mode = ServiceMode.current
        activeMap = map
        activeStore = store
        isPaused = false
        guidance = GuidanceSnapshot(phase: .localizing, destinationLabel: displayName(destination))
        flow.start()
        UIApplication.shared.isIdleTimerDisabled = true
        isBriefing = true
        Announcer.stop()
        Announcer.say(Self.preNavigationBriefing, interrupt: true)
        let token = runToken
        afterSpeechFinishes(token: token) { [weak self] in self?.beginSearch(token: token) }
    }

    /// Creates the guidance service and starts it: the search for the user's position, then guidance.
    private func beginSearch(token: Int) {
        guard token == runToken, flow.step == .active,
              let map = activeMap, let store = activeStore, let destination else { return }
        isBriefing = false
        let service = ServiceFactory.makeGuidanceService(mode: mode, store: store)
        self.service = service
        service.onUpdate = { [weak self] snapshot in self?.receive(snapshot) }
        if !service.speaksForItself {
            Announcer.say("Finding your position. Stand still, then slowly turn left and right.")
        }
        service.start(map: map, destination: destination, from: startNode)
    }

    /// Positioning failed: drop this attempt and search again shortly, until found or the user stops.
    private func searchAgain() {
        service?.onUpdate = nil
        service?.stop()
        service = nil
        runToken += 1
        let token = runToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.beginSearch(token: token) }
    }

    /// Runs `then` once the app's voice has finished the current line (polled; `Speaker` has no callback), or
    /// after 12 s at most. Does nothing if the run was stopped meanwhile.
    private func afterSpeechFinishes(token: Int, waited: TimeInterval = 0, _ then: @escaping () -> Void) {
        let step: TimeInterval = 0.25
        DispatchQueue.main.asyncAfter(deadline: .now() + step) { [weak self] in
            guard let self, token == self.runToken else { return }
            let elapsed = waited + step
            // Wait at least 0.75 s so a line that is just starting counts as speaking.
            if elapsed < 0.75 || (Speaker.shared.isSpeaking && elapsed < 12) {
                self.afterSpeechFinishes(token: token, waited: elapsed, then)
            } else {
                then()
            }
        }
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
        if case .failed(let message) = new.phase, flow.step == .active {
            if message.hasPrefix("There is no route") {
                // Retrying cannot help: say so and go back to the places list.
                stopService()
                flow.stop()
                Announcer.say("\(message) Choose another place.", interrupt: true)
            } else {
                Announcer.say(Self.strugglingMessage, interrupt: true)
                searchAgain()
            }
            return
        }
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
        runToken += 1 // cancels a pending briefing wait or search restart
        isBriefing = false
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
