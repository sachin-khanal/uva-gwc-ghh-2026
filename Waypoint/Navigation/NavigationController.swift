//
// File:     Waypoint/Navigation/NavigationController.swift
// Owner:    B (Navigation/Feedback) with A (Relocalizer) - this is the INTEGRATION POINT.
// Purpose:  Navigator mode brain. Two ways to drive the SAME loop (`tick`):
//             * REAL:      every AR frame (throttled to ~10 Hz) from `Relocalizer` - needs a saved world
//                          map / marker and a Pro iPhone.
//             * SIMULATED: a virtual walker (`PoseSimulator`, WaypointCore) follows the route on a 10 Hz
//                          timer. No scan, no relocalization, no LiDAR needed - so B can tune audio, haptics
//                          and speech on any iPhone, and anyone can demo the cues. Obstacles can be injected.
//           `tick` does, in order:
//             1. obstacle level   (LiDAR depth -> ObstacleClassifier; or the injected value in simulation)
//             2. route + current instruction (RouteFollower) once tracking is OK
//             3. FeedbackPlanner -> speak / haptic / beacon actions, performed by the guide classes.
//           Accessibility (U1, 2026-10-17): also watches HOW THE PHONE IS HELD (`PostureMonitor`) and coaches the user ("The phone is pointing down...");
//           names WHAT is in the way (`ObstacleIdentifier`: mesh class, then Vision) so the user hears "Stop. You are about to walk into a trash can.";
//           and uses route look-ahead for "In 5 meters, turn right." (all wording lives in WaypointCore/Guidance/SpokenPhrases.swift).
// Camera axes: ARKit's camera frame is fixed to the SENSOR. For a phone held upright in portrait: camera +x = toward the BOTTOM of the phone, +y = the
//           user's RIGHT, the camera looks along -z. `Geometry.cameraLocalToUser` converts to the (right, up, back) frame the audio engine expects.
//           (Before 2026-10-17 the real-device beacon used camera-local x as "right", which is wrong in portrait; the simulation hid it.)
// Frames:   map point -> world:  Geometry.transformPoint(mapToWorld, p)
//           world point -> map:  Geometry.transformPoint(mapToWorld.inverse, p)
//           world point -> camera-local (what the audio engine needs): camera.transform.inverse.
//           In simulation mapToWorld is the identity and the "camera" is built from the walker's pose.
// Status:   SCAFFOLD - wired end to end, UNVERIFIED ON DEVICE. The cue logic itself is proven by
//           ScanAndSimulationTests.testEndToEndWalkProducesExpectedCues (`make test`).
//           Live adaptation (2026-10-17, branch feature/route-memory): routes come from `RoutePlanner` (remembered shortest path, re-validated every
//           time). REAL mode only: if the user strays > 6 m from the route, or an obstacle stays at STOP for 4 s, the route is recomputed (the blocked
//           leg is avoided for 10 min); confirmed signs (`SignReader`) are checked against the believed position and LOGGED only (not acted on yet).
//           UNVERIFIED ON DEVICE. TODO(B): tune thresholds in a real hallway; persist `RouteMemory` with the map.
//
import ARKit
import Combine
import WaypointCore

final class NavigationController: ObservableObject {

    // MARK: Published UI state
    @Published private(set) var statusText = "Idle"
    @Published private(set) var instructionText = ""
    @Published private(set) var obstacleLevel: ObstacleLevel = .clear
    @Published private(set) var isSimulating = false
    /// Simulation only: when true the walker "sees" an obstacle 0.5 m ahead.
    @Published var simulatedObstacle = false
    /// Simulation only: freeze the walker in place while the guidance loop keeps running, so an obstacle or a tilted phone can be tried out at leisure
    /// (the walk is only ~15 s long) and so UI tests are not racing the walker.
    @Published var simulationPaused = false
    /// Simulation only: WHAT the simulated obstacle is, so the spoken sentence for each kind can be heard and tested.
    @Published var simulatedObstacleKind: ObstacleKind = .trashCan
    /// Simulation only: pretend the phone is held wrongly.
    @Published var simulatedPosture: SimulatedPosture = .good
    /// The sentence most recently spoken (shown on screen for sighted helpers and read by the UI tests).
    @Published private(set) var lastSpoken = ""
    /// The last few sentences, newest last (for sighted helpers and UI tests: guidance can say two things within a fraction of a second).
    @Published private(set) var recentSpeech: [String] = []
    /// Current phone-position problem in words, or "" when fine.
    @Published private(set) var postureText = ""

    // MARK: Collaborators
    private let relocalizer = Relocalizer()
    private let audio = SpatialAudioGuide()
    private let haptics = HapticsGuide()
    private let speech = SpeechGuide()
    private var planner = FeedbackPlanner()
    private var obstacles = ObstacleClassifier()
    private var postureMonitor = PostureMonitor()
    private let identifier = ObstacleIdentifier()
    private let signReader = SignReader()
    private var routePlanner: RoutePlanner?
    /// Where to save remembered routes (real mode only; simulation does not persist).
    private var memoryHome: (store: MapStore, mapId: UUID)?
    private var blockage = BlockageTracker()
    private var lastReroute: TimeInterval = -100
    private var lastMapPosition: SIMD3<Float> = .zero
    /// A stray further than this from the route polyline triggers a re-route (metres).
    private let offRouteThreshold: Float = 6
    private var simulatedTime: TimeInterval = 0
    private var postureLogCounter = 0

    // MARK: Navigation state
    private var graph: WaypointGraph?
    private var destination: MapNode?
    private var follower: RouteFollower?
    private var lastTick: TimeInterval = 0
    private var beaconLogCounter = 0
    private var lastLoggedKind: GuidanceInstruction.Kind?
    private let tickInterval: TimeInterval = 0.1

    // Simulation state
    private var simulator: PoseSimulator?
    private var simulationTimer: Timer?

    var arSession: ARSession { relocalizer.session }

    // MARK: Start / stop (real)

    func start(map: BuildingMap, destination: MapNode, store: MapStore) {
        begin(map: map, destination: destination)
        // Remembered routes survive app restarts (a cache: re-validated on use, see RoutePlanner).
        memoryHome = (store, map.id)
        routePlanner = RoutePlanner(graph: WaypointGraph(map: map), memory: store.loadRouteMemory(mapId: map.id))
        statusText = "Looking for your position..."
        relocalizer.onFrame = { [weak self] frame in self?.handle(frame) }
        relocalizer.start(map: map, store: store)
        signReader.reset()
        signReader.onRoomNumberConfirmed = { [weak self] number in self?.handleSign(number) }
        Log.nav.info("navigation started -> \(destination.label ?? "?")")
    }

    // MARK: Start (simulated)

    /// Walks a virtual user along the route to `destination`. `startFacingAway` makes the walker begin
    /// facing the wrong way so the "turn around" cue can be heard.
    func startSimulation(map: BuildingMap, destination: MapNode, startFacingAway: Bool = false) {
        begin(map: map, destination: destination)
        let graph = WaypointGraph(map: map)
        guard let startNode = map.nodes.first(where: { $0.kind == .corridor }) ?? map.nodes.first,
              let route = routePlanner?.plan(from: startNode.id, to: destination.id)?.nodes else {
            statusText = "No route in this map"
            return
        }
        follower = RouteFollower(route: route, graph: graph)
        var facing: SIMD3<Float>?
        if startFacingAway, route.count > 1 { facing = route[0].position - route[1].position }
        simulator = PoseSimulator(route: route, startFacing: facing)
        isSimulating = true
        statusText = "Simulating walk"
        Log.nav.info("simulation started -> \(destination.label ?? "?"), \(route.count) nodes")

        simulationTimer = Timer.scheduledTimer(withTimeInterval: tickInterval, repeats: true) { [weak self] _ in
            self?.simulationStep()
        }
    }

    func stop() {
        persistRouteMemory()
        simulationTimer?.invalidate()
        simulationTimer = nil
        simulator = nil
        isSimulating = false
        simulatedObstacle = false
        simulationPaused = false
        relocalizer.onFrame = nil
        signReader.onRoomNumberConfirmed = nil
        relocalizer.stop()
        audio.stop()
        speech.stop()
        statusText = "Stopped"
    }

    // MARK: Shared setup

    private func begin(map: BuildingMap, destination: MapNode) {
        stop() // clean slate if a previous session is still running
        memoryHome = nil // set again by `start` (real mode only)
        let newGraph = WaypointGraph(map: map)
        graph = newGraph
        if let routePlanner { routePlanner.update(graph: newGraph) } else { routePlanner = RoutePlanner(graph: newGraph) }
        routePlanner?.clearAllBlockages()
        blockage.reset()
        self.destination = destination
        follower = nil
        planner.reset()
        obstacles.reset()
        postureMonitor.reset()
        identifier.reset()
        simulatedTime = 0
        lastSpoken = ""
        recentSpeech = []
        postureText = ""

        do { try audio.start() } catch { Log.guidance.error("audio start failed: \(error.localizedDescription)") }
        speech.say("Navigating to \(destination.label ?? "destination"). Walk slowly and look around.", priority: .normal)
    }

    /// PERFORMANCE: assigning an @Published property re-renders the SwiftUI screen even when the value is unchanged, and the loop runs 10x per second.
    /// A constantly-redrawing screen wastes battery and never goes "idle", which also made the UI tests wait minutes. Only publish real changes.
    private func setIfChanged<T: Equatable>(_ keyPath: ReferenceWritableKeyPath<NavigationController, T>, _ value: T) {
        if self[keyPath: keyPath] != value { self[keyPath: keyPath] = value }
    }

    // MARK: Drivers

    /// Real driver: one ARFrame.
    private func handle(_ frame: ARFrame) {
        guard frame.timestamp - lastTick >= tickInterval else { return }
        lastTick = frame.timestamp
        let trackingOK = relocalizer.state == .localized && frame.camera.trackingState == .normal
        setIfChanged(\.statusText, describe(trackingOK: trackingOK))
        // Nearest obstacle straight ahead, in the obstacle band (not floor/ceiling). Say "obstacle" at once; upgrade to "trash can" etc. when
        // identification (mesh class, then Vision) finishes - only spent when something is actually near.
        let hit = ObstacleDetector.centerHit(in: frame)
        var report: ObstacleReport?
        if let hit {
            report = ObstacleReport(kind: .unknown, side: hit.side, distanceMeters: hit.depth, confidence: 0)
            if hit.depth < 2.0 { identifier.request(frame: frame, hit: hit) }
            if let known = identifier.latest, frame.timestamp - known.at < 2.0 {
                report = ObstacleReport(kind: known.report.kind, side: hit.side, distanceMeters: hit.depth, confidence: known.report.confidence)
            }
        }
        if trackingOK { signReader.process(frame) }
        tick(camera: frame.camera.transform, mapToWorld: relocalizer.mapToWorld, trackingOK: trackingOK,
             nearestDepth: hit?.depth, report: report, time: frame.timestamp)
    }

    /// Simulated driver: one timer tick.
    private func simulationStep() {
        guard var sim = simulator else { return }
        if !simulationPaused {
            sim.step(dt: Float(tickInterval))
            simulator = sim
        }
        // Hold the "camera" at 1.4 m so positions are comparable to a real phone; map nodes are at y=0 and
        // routing ignores height.
        let eye = sim.position + SIMD3<Float>(0, 1.4, 0)
        // Same camera convention as a real phone (see the header), optionally held wrongly to exercise the posture coach.
        let camera = Geometry.cameraTransform(position: eye, forward: sim.forward,
                                              pitchDegrees: simulatedPosture.pitchDegrees, rollDegrees: simulatedPosture.rollDegrees)
        simulatedTime += tickInterval
        let report = simulatedObstacle ? ObstacleReport(kind: simulatedObstacleKind, side: .ahead, distanceMeters: 0.5, confidence: 1) : nil
        tick(camera: camera, mapToWorld: matrix_identity_float4x4, trackingOK: true,
             nearestDepth: simulatedObstacle ? 0.5 : nil, report: report, time: simulatedTime)
        if sim.isFinished, follower != nil, instructionText.hasPrefix("arrived") {
            simulationTimer?.invalidate() // stop moving; the arrival cue has already played
            statusText = "Simulation finished"
        }
    }

    // MARK: The shared loop

    private func tick(camera: simd_float4x4, mapToWorld: simd_float4x4, trackingOK: Bool, nearestDepth: Float?,
                      report: ObstacleReport?, time: TimeInterval) {
        let level = obstacles.update(nearest: nearestDepth)
        if level != obstacleLevel { obstacleLevel = level }

        var instruction: GuidanceInstruction?
        if trackingOK, let graph, let destination {
            let worldToMap = mapToWorld.inverse
            // Routing works on the floor plane, so drop the camera height before comparing to map nodes.
            var mapPosition = Geometry.transformPoint(worldToMap, Geometry.translation(of: camera))
            if isSimulating { mapPosition.y = 0 }
            let mapForward = Geometry.transformDirection(worldToMap, Geometry.cameraForward(of: camera))

            lastMapPosition = mapPosition
            if follower == nil { follower = makeFollower(from: mapPosition, graph: graph, destination: destination) }
            if !isSimulating, let f = follower {
                adaptRoute(follower: f, mapPosition: mapPosition, level: level, time: time)
            }
            instruction = follower?.update(position: mapPosition, forward: mapForward)
            if let i = instruction, i.kind != lastLoggedKind {
                lastLoggedKind = i.kind
                Log.nav.info("instruction: \(i.kind.rawValue) bearing=\(Int(i.bearingRadians * 180 / .pi))deg dist=\(String(format: "%.1f", i.distanceMeters))m target=\(i.targetLabel ?? "-")")
            }
            if let i = instruction {
                setIfChanged(\.instructionText, "\(i.kind == .arrived ? "arrived" : i.kind.rawValue), \(String(format: "%.1f", i.distanceMeters)) m")
            }
        }

        // How is the phone being held? (pitch/roll from the camera pose; hysteresis + dwell inside the monitor)
        let posture = postureMonitor.update(cameraTransform: camera, time: time)
        let postureMessage = posture.issue?.message ?? ""
        if postureText != postureMessage { postureText = postureMessage }
        postureLogCounter += 1
        if postureLogCounter % 10 == 1 { // ~1 per second
            Log.nav.info(String(format: "posture: pitch=%.0f roll=%.0f issue=%@", posture.reading.pitchDegrees, posture.reading.rollDegrees, posture.issue?.rawValue ?? "none"))
        }

        let actions = planner.plan(instruction: instruction, obstacle: level, trackingOK: trackingOK,
                                   posture: posture, report: report, time: time)
        perform(actions, camera: camera, mapToWorld: mapToWorld)
    }

    private func makeFollower(from position: SIMD3<Float>, graph: WaypointGraph, destination: MapNode) -> RouteFollower? {
        guard let start = graph.nearestNode(to: position),
              let route = routePlanner?.plan(from: start.id, to: destination.id)?.nodes else {
            Log.nav.error("no route to destination")
            return nil
        }
        Log.nav.info("route has \(route.count) nodes")
        return RouteFollower(route: route, graph: graph)
    }

    private func persistRouteMemory() {
        guard let home = memoryHome, let memory = routePlanner?.memory else { return }
        do { try home.store.saveRouteMemory(memory, mapId: home.mapId) }
        catch { Log.nav.error("could not save route memory: \(error.localizedDescription)") }
    }

    // MARK: Live route adaptation (REAL mode)

    /// Re-route when the user is far off the route or the way ahead stays blocked. Rate-limited so it cannot thrash.
    private func adaptRoute(follower: RouteFollower, mapPosition: SIMD3<Float>, level: ObstacleLevel, time: TimeInterval) {
        guard let graph, let destination, let routePlanner, time - lastReroute > 5 else { return }
        let blockedNow = blockage.update(level: level, time: time)
        let strayed = RoutePlanner.offRouteDistance(position: mapPosition, route: follower.route) > offRouteThreshold
        guard blockedNow || strayed, let here = graph.nearestNode(to: mapPosition) else { return }

        let target = follower.route[follower.targetIndex]
        var plan: PlannedRoute?
        if blockedNow, follower.targetIndex > 0 {
            let previous = follower.route[follower.targetIndex - 1]
            plan = routePlanner.detour(around: (previous.id, target.id), from: here.id, to: destination.id, now: Date())
        } else {
            plan = routePlanner.plan(from: here.id, to: destination.id)
        }
        lastReroute = time
        guard let plan, plan.nodes.map(\.id) != follower.route.map(\.id) else { return }
        self.follower = RouteFollower(route: plan.nodes, graph: graph)
        let words = blockedNow ? "Path blocked. Taking another way." : "Finding a new route."
        setIfChanged(\.lastSpoken, words)
        recentSpeech = Array((recentSpeech + [words]).suffix(6))
        speech.say(words, priority: .high)
        Log.nav.info("re-routed (\(blockedNow ? "blocked" : "off route")): \(plan.nodes.count) nodes, \(String(format: "%.1f", plan.totalDistance)) m")
    }

    /// A sign was read. DELIBERATELY LOG-ONLY for now: a sign can be legible from far down a hall, so acting on a disagreement could
    /// teleport the route. Field data (`sign ... disagrees` lines) should decide whether `.relocate` may re-anchor (TODO B).
    private func handleSign(_ number: String) {
        guard let routePlanner, !isSimulating else { return }
        switch routePlanner.interpretSign(number, userPosition: lastMapPosition) {
        case .consistent(let id): Log.nav.info("sign \(number) confirms position near node \(id)")
        case .relocate(let id): Log.nav.info("sign \(number) disagrees with believed position; it belongs to node \(id) (not acting)")
        case .ambiguous: Log.nav.info("sign \(number) matches several places")
        case .unknown: Log.nav.info("sign \(number) is not in this map")
        }
    }

    /// Executes FeedbackPlanner output. Beacon positions arrive in the MAP frame and are converted
    /// to the camera-local frame here because that is what the audio engine expects.
    private func perform(_ actions: [FeedbackAction], camera: simd_float4x4, mapToWorld: simd_float4x4) {
        for action in actions {
            switch action {
            case .speak(let text, let priority):
                setIfChanged(\.lastSpoken, text)
                recentSpeech = Array((recentSpeech + [text]).suffix(6))
                speech.say(text, priority: priority)
            case .haptic(let cue):
                Log.guidance.info("haptic: \(cue)")
                haptics.play(cue)
            case .beacon(let mapTarget):
                if var mapTarget {
                    if isSimulating { mapTarget.y = 1.4 } // match the simulated eye height so the beacon is level
                    let world = Geometry.transformPoint(mapToWorld, mapTarget)
                    // ARKit camera-local -> the user frame (x right, y up, z back) that the audio engine uses. NOT a plain `camera.inverse * world`:
                    // in portrait the camera's local x axis points toward the bottom of the phone, not to the user's right.
                    let local = Geometry.cameraLocalToUser(Geometry.transformPoint(camera.inverse, world))
                    beaconLogCounter += 1
                    if beaconLogCounter % 10 == 1 { // ~1 per second
                        Log.guidance.info(String(format: "beacon user x=%.2f (right+) y=%.2f (up+) z=%.2f (ahead-) dist=%.1f m", local.x, local.y, local.z, simd_length(local)))
                    }
                    audio.setTarget(relativeToListener: local)
                } else {
                    audio.setTarget(relativeToListener: nil)
                }
            }
        }
    }

    private func describe(trackingOK: Bool) -> String {
        switch relocalizer.state {
        case .idle: return "Idle"
        case .searching: return "Looking for your position..."
        case .lost: return "Position lost. Hold still."
        case .localized: return trackingOK ? "Navigating" : "Tracking limited"
        }
    }
}

/// How the simulated phone is "held", for testing the posture coach without moving a real phone.
enum SimulatedPosture: String, CaseIterable, Identifiable {
    case good, tiltedDown, tiltedUp, leaningLeft, leaningRight, sideways

    var id: String { rawValue }
    var pitchDegrees: Float {
        switch self {
        case .tiltedDown: return -50
        case .tiltedUp: return 55
        default: return 0
        }
    }
    var rollDegrees: Float {
        switch self {
        case .leaningLeft: return -40
        case .leaningRight: return 40
        case .sideways: return 90
        default: return 0
        }
    }
}
