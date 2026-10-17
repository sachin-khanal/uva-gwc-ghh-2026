//
// File:     Waypoint/Navigation/NavigationController.swift
// Owner:    B (Navigation/Feedback) with A (Relocalizer) - this is the INTEGRATION POINT.
// Purpose:  Navigator mode brain. Every AR frame (throttled to ~10 Hz) it:
//             1. asks Relocalizer whether we are localized,
//             2. converts the camera pose from WORLD frame into the MAP frame,
//             3. builds a route (first time) and asks RouteFollower for the current instruction,
//             4. reads LiDAR depth -> ObstacleClassifier -> obstacle level,
//             5. asks FeedbackPlanner what to do, and performs the actions via
//                SpatialAudioGuide / HapticsGuide / SpeechGuide.
// Frames:   map point -> world:  Geometry.transformPoint(mapToWorld, p)
//           world point -> map:  Geometry.transformPoint(mapToWorld.inverse, p)
//           world point -> camera-local (what the audio engine needs): camera.transform.inverse.
// Status:   SCAFFOLD - wired end to end, untested on a device. First integration milestone
//           (hour ~8-14) is making this walk the sample map / a real scan.
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

    // MARK: Collaborators
    private let relocalizer = Relocalizer()
    private let audio = SpatialAudioGuide()
    private let haptics = HapticsGuide()
    private let speech = SpeechGuide()
    private var planner = FeedbackPlanner()
    private var obstacles = ObstacleClassifier()

    // MARK: Navigation state
    private var graph: WaypointGraph?
    private var destination: MapNode?
    private var follower: RouteFollower?
    private var lastTick: TimeInterval = 0
    private let tickInterval: TimeInterval = 0.1

    var arSession: ARSession { relocalizer.session }

    func start(map: BuildingMap, destination: MapNode, store: MapStore) {
        graph = WaypointGraph(map: map)
        self.destination = destination
        follower = nil
        planner.reset()
        obstacles.reset()
        statusText = "Looking for your position..."

        do { try audio.start() } catch { Log.guidance.error("audio start failed: \(error.localizedDescription)") }
        speech.say("Navigating to \(destination.label ?? "destination"). Walk slowly and look around.", priority: .normal)

        relocalizer.onFrame = { [weak self] frame in self?.handle(frame) }
        relocalizer.start(map: map, store: store)
        Log.nav.info("navigation started -> \(destination.label ?? "?")")
    }

    func stop() {
        relocalizer.onFrame = nil
        relocalizer.stop()
        audio.stop()
        speech.stop()
        statusText = "Stopped"
    }

    // MARK: Per-frame loop

    private func handle(_ frame: ARFrame) {
        guard frame.timestamp - lastTick >= tickInterval else { return }
        lastTick = frame.timestamp

        let trackingOK = relocalizer.state == .localized && frame.camera.trackingState == .normal
        let level = obstacles.update(nearest: ObstacleDetector.nearestDepth(in: frame))
        if level != obstacleLevel { obstacleLevel = level }

        var instruction: GuidanceInstruction?
        if trackingOK, let graph, let destination {
            let worldToMap = relocalizer.mapToWorld.inverse
            let camera = frame.camera.transform
            let mapPosition = Geometry.transformPoint(worldToMap, Geometry.translation(of: camera))
            let mapForward = Geometry.transformDirection(worldToMap, Geometry.cameraForward(of: camera))

            if follower == nil { follower = makeFollower(from: mapPosition, graph: graph, destination: destination) }
            instruction = follower?.update(position: mapPosition, forward: mapForward)
            if let i = instruction {
                instructionText = "\(i.kind.rawValue), \(String(format: "%.1f", i.distanceMeters)) m"
            }
        }
        statusText = describe(trackingOK: trackingOK)

        let actions = planner.plan(instruction: instruction, obstacle: level, trackingOK: trackingOK)
        perform(actions, camera: frame.camera.transform)
    }

    private func makeFollower(from position: SIMD3<Float>, graph: WaypointGraph, destination: MapNode) -> RouteFollower? {
        guard let start = graph.nearestNode(to: position),
              let route = Router.route(in: graph, from: start.id, to: destination.id) else {
            Log.nav.error("no route to destination")
            return nil
        }
        Log.nav.info("route has \(route.count) nodes")
        return RouteFollower(route: route, graph: graph)
    }

    /// Executes FeedbackPlanner output. Beacon positions arrive in the MAP frame and are converted
    /// to the camera-local frame here because that is what the audio engine expects.
    private func perform(_ actions: [FeedbackAction], camera: simd_float4x4) {
        for action in actions {
            switch action {
            case .speak(let text, let priority):
                speech.say(text, priority: priority)
            case .haptic(let cue):
                haptics.play(cue)
            case .beacon(let mapTarget):
                if let mapTarget {
                    let world = Geometry.transformPoint(relocalizer.mapToWorld, mapTarget)
                    let local = Geometry.transformPoint(camera.inverse, world)
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
