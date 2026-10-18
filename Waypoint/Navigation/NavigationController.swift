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
    private let signReader = SignReader()
    private var routePlanner: RoutePlanner?
    /// What the sensors say about the surroundings right now (room on each side, how close ahead). Feeds warnings and the opening briefing.
    private var sceneContext: SceneContext?
    private var openingQueued = false
    /// The text of the opening briefing, so the speaker can be told it must not be dropped as stale (see Speaker.openingMaxQueuedAge).
    private var openingBriefingText: String?
    /// Gemini rewording for the calm lines; nil when no key is configured, the setting is off, or the app is not navigating. Every failure
    /// falls back to the plain sentence (see Narration.swift). Never used for obstacles, turns, posture, lost position or arrival.
    private var narration: NarrationCoordinator?
    /// Bumped on every `begin`/`stop`, so a rewrite that comes back after navigation ended or restarted is not spoken.
    private var navigationGeneration = 0
    /// Rewritten text -> the plain sentence the planner knows it by (for `FeedbackPlanner.lineLost`). Small: only recent lines matter.
    private var spokenAliases: [String: String] = [:]
    /// Keeps a busy voice from turning every displaced line into a re-announcement next tick (see `LossThrottle`).
    private var lossThrottle = LossThrottle()
    /// Where to save remembered routes (real mode only; simulation does not persist).
    private var memoryHome: (store: MapStore, mapId: UUID)?
    private var blockage = BlockageTracker()
    private var lastReroute: TimeInterval = -100
    /// A stray further than this from the route polyline triggers a re-route (metres).
    private let offRouteThreshold: Float = 6
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
    private var lastMovementSample: (position: SIMD3<Float>, yaw: Float, time: TimeInterval)?
    private var isMoving = true
    /// Below this speed we treat the user as standing still. A slow shuffle is ~0.3 m/s; this is well
    /// under that, so only a genuine stop counts.
    private static let movingSpeed: Float = 0.15
    /// How far apart movement samples are taken. Shorter than this and ARKit's pose noise looks like
    /// walking; longer and we react too slowly.
    private static let movementSampleSeconds: TimeInterval = 0.6
    /// Turning on the spot counts as moving, because the camera then sees a genuinely different scene
    /// and a new obstacle really can appear. Translation alone is not enough: a user who pivots to
    /// face a doorway has not travelled a centimetre (team note 2026-10-18 - "gyroscope for left/right
    /// turn"). Taken from the ARKit camera yaw, so it needs no CoreMotion and no `NSMotionUsageDescription`.
    private static let turningDegreesPerSecond: Float = 25
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
        // Remembered routes survive app restarts (a cache: re-validated on use, see RoutePlanner).
        memoryHome = (store, map.id)
        routePlanner = RoutePlanner(graph: WaypointGraph(map: map), memory: store.loadRouteMemory(mapId: map.id))
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
        persistRouteMemory()
        simulationTimer?.invalidate()
        simulationTimer = nil
        simulator = nil
        isSimulating = false
        simulatedObstacle = false
        simulationPaused = false
        relocalizer.onFrame = nil
        signReader.onRoomNumberConfirmed = nil
        relocalizerPreparing = nil
        isPreparing = false
        relocalizer.stop()
        audio.stop()
        speech.onLineLost(nil)
        speech.stop()
        navigationGeneration += 1
        narration = nil
        spokenAliases = [:]
        lossThrottle.reset()
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
        narration = Self.makeNarration()
        // A line the speaker threw away (displaced, expired, cut off by a warning) was already recorded by the planner as announced: tell it,
        // so it is said again if it still applies.
        speech.onLineLost { [weak self] text in
            guard let self else { return }
            let plain = self.spokenAliases[text] ?? text
            if self.lossThrottle.shouldRearm(plain, now: ProcessInfo.processInfo.systemUptime) { self.planner.lineLost(plain) }
        }
        openingQueued = false
        openingBriefingText = nil
        sceneContext = nil
        // Short on purpose: the full "where you are / what is around / how to go" briefing follows as soon as the position has settled.
        speech.say("Navigating to \(destination.label ?? "your destination").", priority: .normal)
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
        sceneContext = ObstacleDetector.sideClearances(in: frame, ahead: hit?.depth)
        if trackingOK { signReader.process(frame) }
        // Is there a clearly better way round? Suggestion only - see AvoidanceAdvisor's safety note.
        // Side room comes from the WIDE scan (`sceneContext`), not from `hit.clearance`. The latter is
        // built inside `centerHit`, which only samples the middle 28% of the frame
        // (`corridorRowFractions`) and splits left/right at +/-0.35 m - a band so narrow it can barely
        // see sideways, so both sides came back nil or near-identical, no side ever won by
        // `decisiveMargin`, and `advise` returned nil almost every time. The user got "Stop." with no
        // way round even when there was obviously room to one side (device report 2026-10-18).
        // `sideClearances` scans the full width and measures how far the nearest thing on each side is
        // from the centre line, which is exactly the question "can I step that way".
        let clearance = AvoidanceAdvisor.Clearance(ahead: hit?.depth,
                                                   left: sceneContext?.leftClearance,
                                                   right: sceneContext?.rightClearance)
        let avoidTowards = avoidance.advise(clearance)
        // ...and if there is not, the user still needs somewhere to go. Must be asked AFTER `advise`,
        // which is what knows whether a way round was found (F-5, 2026-10-18).
        let backUp = avoidance.isBoxedIn(clearance)
        tick(camera: frame.camera.transform, mapToWorld: relocalizer.mapToWorld, trackingOK: trackingOK,
             nearestDepth: hit?.depth, report: report, time: frame.timestamp, avoidTowards: avoidTowards,
             backUp: backUp)
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
        // Pretend the depth sensor sees a wall on the right and open space on the left, so the "way out" hint can be heard in simulation.
        sceneContext = simulatedObstacle ? SceneContext(leftClearance: 2.5, rightClearance: 0.4, aheadClearance: 0.5) : nil
        tick(camera: camera, mapToWorld: matrix_identity_float4x4, trackingOK: true,
             nearestDepth: simulatedObstacle ? 0.5 : nil, report: report, time: simulatedTime)
        if sim.isFinished, follower != nil, instructionText.hasPrefix("arrived") {
            simulationTimer?.invalidate() // stop moving; the arrival cue has already played
            statusText = "Simulation finished"
        }
    }

    // MARK: The shared loop

    private func tick(camera: simd_float4x4, mapToWorld: simd_float4x4, trackingOK: Bool, nearestDepth: Float?,
                      report: ObstacleReport?, time: TimeInterval, avoidTowards: Side? = nil,
                      backUp: Bool = false) {
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

            if !openingQueued, let f = follower {
                // Once per navigation: where you are, what is around, how to get there (kept short; see StartBriefing).
                openingQueued = true
                let first = f.update(position: mapPosition, forward: mapForward)
                if first.kind != .arrived {
                    let opening = StartBriefing.text(position: mapPosition, forward: mapForward, graph: graph, route: f.route,
                                                     destination: destination, context: sceneContext, firstManeuver: first.upcoming)
                    openingBriefingText = opening
                    planner.queueBriefing(opening)
                }
            }
            // Only publish real changes (see setIfChanged): at 10 Hz an unconditional assignment keeps the screen redrawing and the UI tests never idle.
            setIfChanged(\.mapPosition, mapPosition)
            setIfChanged(\.headingRadians, atan2(mapForward.x, -mapForward.z))
            if !jumped {
                let forward = Geometry.cameraForward(of: camera)
                updateMovement(position: mapPosition, yaw: atan2(forward.x, -forward.z), time: time)
            }
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
            // Our addition (feature/route-memory): a path that stays blocked (STOP for several seconds) is detoured for a while.
            if !isSimulating, let current = follower {
                detourIfBlocked(follower: current, mapPosition: mapPosition, level: level, time: time)
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
                                   posture: posture, report: report, time: time, context: sceneContext, isMoving: isMoving,
                                   avoidTowards: avoidTowards, backUp: backUp)
        perform(actions, camera: camera, mapToWorld: mapToWorld)
    }

    /// Are they walking? Measured from the camera pose, so it needs no extra framework and no motion
    /// permission - CMPedometer/CMMotionActivity would need `NSMotionUsageDescription` and would tell
    /// us about the PHONE, while the pose tells us about the user's position in the map.
    /// Used to stop repeating "stop, there is a door ahead" at somebody who has already stopped.
    private func updateMovement(position: SIMD3<Float>, yaw: Float, time: TimeInterval) {
        guard let last = lastMovementSample else {
            lastMovementSample = (position, yaw, time)
            return
        }
        let elapsed = time - last.time
        guard elapsed >= Self.movementSampleSeconds else { return }
        let travelled = Geometry.horizontalDistance(last.position, position)
        let walking = travelled / Float(elapsed) >= Self.movingSpeed
        // Shortest way round the circle, so crossing +/-pi is not read as a spin.
        var turned = abs(yaw - last.yaw).truncatingRemainder(dividingBy: 2 * .pi)
        if turned > .pi { turned = 2 * .pi - turned }
        let turning = (turned * 180 / .pi) / Float(elapsed) >= Self.turningDegreesPerSecond
        isMoving = walking || turning
        lastMovementSample = (position, yaw, time)
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
        // From where the user STANDS, not from whichever node is nearest: on a loop the nearest node can be on the wrong branch and send them
        // the long way round. RoutePlanner tries several nearby starts and reuses remembered shortest routes (re-validated every time).
        guard let route = routePlanner?.plan(fromPosition: position, to: destination.id)?.nodes else {
            Log.nav.error("no route to destination")
            return nil
        }
        Log.nav.info("route has \(route.count) nodes, \(String(format: "%.1f", Router.length(of: route))) m")
        return RouteFollower(route: route, graph: graph)
    }

    private func persistRouteMemory() {
        guard let home = memoryHome, let memory = routePlanner?.memory else { return }
        do { try home.store.saveRouteMemory(memory, mapId: home.mapId) }
        catch { Log.nav.error("could not save route memory: \(error.localizedDescription)") }
    }

    // MARK: Live route adaptation (REAL mode)

    /// The way ahead has been blocked (obstacle at STOP) for several seconds: avoid that leg for a while and walk another way if there is one.
    /// Off-route recovery is separate (distanceFromRoute in `tick`). Rate-limited so it cannot thrash.
    private func detourIfBlocked(follower: RouteFollower, mapPosition: SIMD3<Float>, level: ObstacleLevel, time: TimeInterval) {
        guard let graph, let destination, let routePlanner, time - lastReroute > 5 else { return }
        guard blockage.update(level: level, time: time), follower.targetIndex > 0,
              let here = graph.nearestNode(to: mapPosition) else { return }
        let previous = follower.route[follower.targetIndex - 1], target = follower.route[follower.targetIndex]
        lastReroute = time
        guard let plan = routePlanner.detour(around: (previous.id, target.id), from: here.id, to: destination.id, now: Date()),
              plan.nodes.map(\.id) != follower.route.map(\.id) else { return }
        self.follower = RouteFollower(route: plan.nodes, graph: graph)
        routeNodeIds = plan.nodes.map(\.id)
        lastRouteWorldKey = ""
        planner.reset()
        speech.say("Path blocked. Taking another way.", priority: .high)
        Log.nav.info("detour around blockage: \(plan.nodes.count) waypoints, \(String(format: "%.1f", plan.totalDistance)) m")
    }

    /// A sign was read. DELIBERATELY LOG-ONLY for now: a sign can be legible from far down a hall, so acting on a disagreement could
    /// teleport the route. Field data (`sign ... disagrees` lines) should decide whether `.relocate` may re-anchor (TODO B).
    private func handleSign(_ number: String) {
        guard let routePlanner, !isSimulating else { return }
        switch routePlanner.interpretSign(number, userPosition: mapPosition ?? .zero) {
        case .consistent(let id):
            Log.nav.info("sign \(number) confirms position near node \(id)")
            // Contextual awareness from the camera: tell the user what the sign says, once. Silent after arrival (the planner is latched).
            if instructionText.hasPrefix("arrived") { return }
            let isDestination = destination?.id == id
            let text = SignSpeech.text(read: number, isDestination: isDestination)
            setIfChanged(\.lastSpoken, text)
            recentSpeech = Array((recentSpeech + [text]).suffix(6))
            speech.say(text, priority: .normal)
        case .relocate(let id): Log.nav.info("sign \(number) disagrees with believed position; it belongs to node \(id) (not acting)")
        case .ambiguous: Log.nav.info("sign \(number) matches several places")
        case .unknown: Log.nav.info("sign \(number) is not in this map")
        }
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
            // ARRIVAL must never wait or be dropped as stale behind a longer line (the opening briefing, a countdown): once you are there, whatever is
            // still being said is out of date. It interrupts, like a safety cue (found on the phone 2026-10-18: "You have arrived" was dropped after
            // 2.7 s queued behind the briefing in the simulated walk).
            let isArrival = line.text.hasPrefix("You have arrived")
            let priority: SpeechPriority = isArrival ? .critical : line.priority
            let staysFresh = line.text == openingBriefingText
            // Only calm lines carry a `narration` fact (the planner decides; see FeedbackPlanner.note) - never an obstacle, turn, posture or arrival.
            if !isArrival, let fact = planner.info(for: line.text)?.narration, let narration {
                let generation = navigationGeneration
                let plain = line.text
                Task { [weak self] in
                    let rich = await narration.narrate(fact) // nil on ANY failure -> the plain sentence
                    DispatchQueue.main.async {
                        guard let self, self.navigationGeneration == generation else { return }
                        var text = plain
                        if let rich {
                            text = rich
                            self.spokenAliases[rich] = plain
                            if self.spokenAliases.count > 12 { self.spokenAliases = [rich: plain] }
                            self.setIfChanged(\.lastSpoken, rich)
                            if let i = self.recentSpeech.lastIndex(of: plain) { self.recentSpeech[i] = rich }
                            Log.guidance.info("narrated: \(plain) -> \(rich)")
                        }
                        self.speech.say(text, priority: priority, staysFresh: staysFresh, clearsQueue: isArrival)
                    }
                }
            } else {
                speech.say(line.text, priority: priority, staysFresh: staysFresh, clearsQueue: isArrival)
            }
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

    /// Richer wording for the calm lines, or nil (= plain sentences). Two routes, in this order:
    ///  1. the `narrate` Edge Function through the signed-in Supabase client: the Gemini key lives on the server and in NO build (D-047);
    ///  2. DEVELOPER FALLBACK only when cloud is not configured at all: a Gemini key in Config/Local.xcconfig, called directly.
    private static func makeNarration() -> NarrationCoordinator? {
        guard UIPrefs.richNarrationEnabled else { return nil }
        if let client = SharedCloud.client {
            // Sign in now, so the first rewrite does not spend its 1.5 s deadline on the anonymous sign-up.
            Task { _ = try? await client.ensureSession() }
            Log.guidance.info("narration: via the narrate Edge Function")
            return NarrationCoordinator(narrator: ProxyNarrator(caller: client))
        }
        guard let config = GeminiConfig.validated(apiKey: Bundle.main.object(forInfoDictionaryKey: "GeminiApiKey") as? String,
                                                  model: Bundle.main.object(forInfoDictionaryKey: "GeminiModel") as? String)
        else { return nil }
        Log.guidance.info("narration: Gemini \(config.model)")
        return NarrationCoordinator(narrator: GeminiNarrator(config: config))
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
