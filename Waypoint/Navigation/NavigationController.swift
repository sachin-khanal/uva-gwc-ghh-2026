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
//           TODO(B): re-route if the user wanders far off the route; sign-reader announcements.
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

    // MARK: Debug telemetry (for the on-screen debug overlay; see NavDebugView)
    /// The map being navigated, so the overlay can draw the floor plan.
    @Published private(set) var activeMap: BuildingMap?
    /// The computed route, start first. Empty until the route exists.
    @Published private(set) var routeNodeIds: [UUID] = []
    /// Where we think the user is, in the MAP frame. nil until relocalized.
    @Published private(set) var mapPosition: SIMD3<Float>?
    /// Which way they face in the map frame: radians, 0 = -z, positive = toward +x.
    @Published private(set) var headingRadians: Float?
    /// The route's waypoints in ARKit WORLD coordinates, for drawing over the camera. Empty until the
    /// route exists and we are localized. Recomputed only when the route or the map->world transform
    /// changes, because this feeds a RealityKit scene rebuild.
    @Published private(set) var routeWorldPositions: [SIMD3<Float>] = []
    private var lastRouteWorldKey: String = ""

    // MARK: Collaborators
    private let relocalizer = Relocalizer()
    private var relocalizerPreparing: AnyCancellable?

    /// True while the saved scan is being read and decoded, before the camera starts. The UI shows a
    /// loading state instead of appearing frozen (device report 2026-10-17).
    @Published private(set) var isPreparing = false
    private let audio = SpatialAudioGuide()
    private let haptics = HapticsGuide()
    private let speech = SpeechGuide()
    private var planner = FeedbackPlanner()
    private var obstacles = ObstacleClassifier()
    private var postureMonitor = PostureMonitor()
    /// Suggests a way round a blocked path, so a cue can say why it is asking for a turn.
    private var avoidance = AvoidanceAdvisor()
    private let identifier = ObstacleIdentifier()
    private var simulatedTime: TimeInterval = 0
    private var postureLogCounter = 0

    // MARK: Navigation state
    private var graph: WaypointGraph?
    private var destination: MapNode?
    private var follower: RouteFollower?
    /// Holds the first route back until the relocalized pose has settled (see StartGate).
    private var startGate = StartGate()
    /// How often the route is recomputed from the CURRENT position. A* over a few hundred nodes is
    /// microseconds; this interval is about not thrashing the published route, not about cost.
    private static let routeRecomputeSeconds: TimeInterval = 0.5
    private var lastRouteComputation: TimeInterval = -.greatestFiniteMagnitude
    private var lastRerouteAnnouncement: TimeInterval = -.greatestFiniteMagnitude
    /// Recent positions, for working out whether the user is actually walking.
    private var lastMovementSample: (position: SIMD3<Float>, time: TimeInterval)?
    private var isMoving = true
    /// Below this speed we treat the user as standing still. A slow shuffle is ~0.3 m/s; this is well
    /// under that, so only a genuine stop counts.
    private static let movingSpeed: Float = 0.15
    /// How far apart movement samples are taken. Shorter than this and ARKit's pose noise looks like
    /// walking; longer and we react too slowly.
    private static let movementSampleSeconds: TimeInterval = 0.6
    /// How far off the route counts as "off route". Still wider than a corridor so normal drift is
    /// ignored, but 5 m meant walking the wrong way for several seconds before anything happened
    /// (device report 2026-10-17).
    private static let rerouteMeters: Float = 3
    /// A position change larger than this between ticks is not walking - it is relocalization
    /// correcting itself. Treating it as walking made the app think the user had left the route and
    /// re-route, over and over (device report 2026-10-17). 3 m in a 0.1 s tick is 30 m/s.
    private static let poseJumpMeters: Float = 3
    /// How often we are willing to SAY "Recalculating". The computation is continuous now; the
    /// SPEECH is what must not machine-gun.
    private static let minimumSecondsBetweenReroutes: TimeInterval = 5
    private var lastTickPosition: SIMD3<Float>?
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
        statusText = "Looking for your position..."
        relocalizer.onFrame = { [weak self] frame in self?.handle(frame) }
        // Mirror the loading flag and say so out loud: "Looking for your position" is misleading while
        // we have not even opened the file yet.
        relocalizerPreparing = relocalizer.$isPreparing
            .receive(on: RunLoop.main)
            .sink { [weak self] preparing in
                guard let self else { return }
                self.isPreparing = preparing
                if preparing {
                    self.setIfChanged(\.statusText, "Opening the saved scan...")
                } else if self.statusText == "Opening the saved scan..." {
                    self.setIfChanged(\.statusText, "Looking for your position...")
                }
            }
        relocalizer.start(map: map, store: store)
        Log.nav.info("navigation started -> \(destination.label ?? "?")")
    }

    // MARK: Start (simulated)

    /// Walks a virtual user along the route to `destination`. `startFacingAway` makes the walker begin
    /// facing the wrong way so the "turn around" cue can be heard.
    func startSimulation(map: BuildingMap, destination: MapNode, startFacingAway: Bool = false) {
        begin(map: map, destination: destination)
        let graph = WaypointGraph(map: map)
        guard let startNode = map.nodes.first(where: { $0.kind == .corridor }) ?? map.nodes.first,
              let route = Router.route(in: graph, from: startNode.id, to: destination.id) else {
            statusText = "No route in this map"
            return
        }
        follower = RouteFollower(route: route, graph: graph)
        routeNodeIds = route.map(\.id)
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
        simulationTimer?.invalidate()
        simulationTimer = nil
        simulator = nil
        isSimulating = false
        simulatedObstacle = false
        simulationPaused = false
        relocalizer.onFrame = nil
        relocalizerPreparing = nil
        isPreparing = false
        relocalizer.stop()
        audio.stop()
        speech.stop()
        statusText = "Stopped"
    }

    // MARK: Shared setup

    private func begin(map: BuildingMap, destination: MapNode) {
        stop() // clean slate if a previous session is still running
        graph = WaypointGraph(map: map)
        activeMap = map
        routeNodeIds = []
        mapPosition = nil
        headingRadians = nil
        self.destination = destination
        follower = nil
        lastMovementSample = nil
        isMoving = true
        lastTickPosition = nil
        lastRouteComputation = -.greatestFiniteMagnitude
        lastRerouteAnnouncement = -.greatestFiniteMagnitude
        routeWorldPositions = []
        lastRouteWorldKey = ""
        startGate.reset()
        planner.reset()
        obstacles.reset()
        postureMonitor.reset()
        avoidance.reset()
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
        // Is there a clearly better way round? Suggestion only - see AvoidanceAdvisor's safety note.
        let avoidTowards = avoidance.advise(hit?.clearance ?? .init())
        tick(camera: frame.camera.transform, mapToWorld: relocalizer.mapToWorld, trackingOK: trackingOK,
             nearestDepth: hit?.depth, report: report, time: frame.timestamp, avoidTowards: avoidTowards)
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
                      report: ObstacleReport?, time: TimeInterval, avoidTowards: Side? = nil) {
        let level = obstacles.update(nearest: nearestDepth)
        if level != obstacleLevel { obstacleLevel = level }

        var instruction: GuidanceInstruction?
        if trackingOK, let graph, let destination {
            let worldToMap = mapToWorld.inverse
            // Routing works on the floor plane, so drop the camera height before comparing to map nodes.
            var mapPosition = Geometry.transformPoint(worldToMap, Geometry.translation(of: camera))
            if isSimulating { mapPosition.y = 0 }
            let mapForward = Geometry.transformDirection(worldToMap, Geometry.cameraForward(of: camera))

            // Do NOT route from the first pose that arrives: just after relocalization it is still
            // converging and often sits near the session origin, i.e. where the scan STARTED. Routing
            // from there walks the user back to the beginning of the scan first (device report
            // 2026-10-17). Wait for the pose to hold still, then route from where they really are.
            if follower == nil, startGate.update(position: mapPosition, trackingOK: trackingOK) {
                follower = makeFollower(from: mapPosition, graph: graph, destination: destination)
                routeNodeIds = follower?.route.map(\.id) ?? []
            }
            // A position change larger than a person can walk between ticks is relocalization
            // correcting itself, not movement. It must not be read as walking.
            let jumped = lastTickPosition.map {
                Geometry.horizontalDistance($0, mapPosition) > Self.poseJumpMeters
            } ?? false
            lastTickPosition = mapPosition
            if jumped { lastMovementSample = nil }

            self.mapPosition = mapPosition
            headingRadians = atan2(mapForward.x, -mapForward.z)
            if !jumped { updateMovement(position: mapPosition, time: time) }
            updateRouteWorldPositions(mapToWorld: mapToWorld)

            // ROUTE CONTINUOUSLY, rather than deciding when the old route has gone stale.
            //
            // Three attempts at that decision each fixed one case and broke another - off-route
            // counters, drift detection, pose-jump suppression - and the user still ended up following
            // a route that started where they had never been (device reports, 2026-10-17). A* over a
            // few hundred nodes is cheap, so the route is simply recomputed from the CURRENT position
            // a couple of times a second. It cannot be stale, whatever the pose does.
            //
            // Speech is what needs rationing, not computation: a new route is adopted silently, and
            // "Recalculating" is said only when the user had genuinely wandered off the old one.
            if follower != nil, time - lastRouteComputation >= Self.routeRecomputeSeconds {
                lastRouteComputation = time
                let strayed = follower.map { $0.distanceFromRoute(position: mapPosition) > Self.rerouteMeters } ?? false
                if let rebuilt = makeFollower(from: mapPosition, graph: graph, destination: destination) {
                    let changed = rebuilt.route.map(\.id) != routeNodeIds
                    follower = rebuilt
                    if changed {
                        routeNodeIds = rebuilt.route.map(\.id)
                        lastRouteWorldKey = ""
                        // Diagnostic: if the route ever starts somewhere the user is not, these two
                        // numbers say so immediately instead of needing another walk to guess from.
                        if let first = rebuilt.route.first {
                            Log.nav.info(String(format: "route from (%.1f, %.1f) starts at (%.1f, %.1f), %.1f m away, %d waypoints",
                                                mapPosition.x, mapPosition.z,
                                                first.position.x, first.position.z,
                                                Geometry.horizontalDistance(mapPosition, first.position),
                                                rebuilt.route.count))
                        }
                        if strayed, time - lastRerouteAnnouncement >= Self.minimumSecondsBetweenReroutes {
                            lastRerouteAnnouncement = time
                            speech.say("Recalculating.", priority: .high)
                            Log.nav.info("re-routed: \(rebuilt.route.count) waypoints, user was off route")
                        }
                    }
                }
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
                                   posture: posture, report: report, time: time, isMoving: isMoving,
                                   avoidTowards: avoidTowards)
        perform(actions, camera: camera, mapToWorld: mapToWorld)
    }

    /// Are they walking? Measured from the camera pose, so it needs no extra framework and no motion
    /// permission - CMPedometer/CMMotionActivity would need `NSMotionUsageDescription` and would tell
    /// us about the PHONE, while the pose tells us about the user's position in the map.
    /// Used to stop repeating "stop, there is a door ahead" at somebody who has already stopped.
    private func updateMovement(position: SIMD3<Float>, time: TimeInterval) {
        guard let last = lastMovementSample else {
            lastMovementSample = (position, time)
            return
        }
        let elapsed = time - last.time
        guard elapsed >= Self.movementSampleSeconds else { return }
        let travelled = Geometry.horizontalDistance(last.position, position)
        isMoving = travelled / Float(elapsed) >= Self.movingSpeed
        lastMovementSample = (position, time)
    }

    /// Route waypoints in world space for the AR overlay. Cheap guard: only rebuild when the route or
    /// the transform actually changed, since the tick runs 10x a second and this drives a scene rebuild.
    private func updateRouteWorldPositions(mapToWorld: simd_float4x4) {
        guard let follower else {
            if !routeWorldPositions.isEmpty { routeWorldPositions = [] }
            return
        }
        let t = mapToWorld.columns.3
        let key = "\(follower.route.count)-\(routeNodeIds.first?.uuidString ?? "")-" +
            String(format: "%.2f,%.2f,%.2f", t.x, t.y, t.z)
        guard key != lastRouteWorldKey else { return }
        lastRouteWorldKey = key
        routeWorldPositions = follower.route.map { Geometry.transformPoint(mapToWorld, $0.position) }
    }

    private func makeFollower(from position: SIMD3<Float>, graph: WaypointGraph, destination: MapNode) -> RouteFollower? {
        // From where the user STANDS, not from whichever node is nearest: on a loop the nearest node
        // can be on the wrong branch and send them the long way round.
        guard let route = Router.bestRoute(in: graph, from: position, to: destination.id) else {
            Log.nav.error("no route to destination")
            return nil
        }
        Log.nav.info("route has \(route.count) nodes, \(String(format: "%.1f", Router.length(of: route))) m")
        return RouteFollower(route: route, graph: graph)
    }

    /// Executes FeedbackPlanner output. Beacon positions arrive in the MAP frame and are converted
    /// to the camera-local frame here because that is what the audio engine expects.
    private func perform(_ actions: [FeedbackAction], camera: simd_float4x4, mapToWorld: simd_float4x4) {
        // ONE MOVE AT A TIME. A tick can produce several `.speak` actions (a turn, a landmark, a
        // hazard). Joining them into a single utterance stopped them clipping each other, but it
        // produced run-on paragraphs - "Walk straight about 8 meters, then turn left. Turn around. I..."
        // - instead of the one thing to do now (device report 2026-10-17).
        // They are handed over SEPARATELY, most important first: `Speaker` says the first and holds at
        // most one more, so the user hears a single instruction and then, if it still applies a moment
        // later, the next one.
        let spoken = actions
            .compactMap { action -> (text: String, priority: SpeechPriority)? in
                if case .speak(let text, let priority) = action { return (text, priority) }
                return nil
            }
            .sorted { $0.priority > $1.priority } // stable: equal priorities keep planner order
        if let first = spoken.first {
            setIfChanged(\.lastSpoken, first.text)
            recentSpeech = Array((recentSpeech + [first.text]).suffix(6))
        }
        for line in spoken {
            speech.say(line.text, priority: line.priority)
        }

        for action in actions {
            switch action {
            case .speak:
                break // already said, coalesced above
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
