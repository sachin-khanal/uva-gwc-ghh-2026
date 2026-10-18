//
// File:     Waypoint/Capture/CaptureController.swift
// Owner:    A (AR/Maps)
// Purpose:  Volunteer mode engine. Runs an ARSession with LiDAR scene reconstruction, feeds the
//           camera position into `MapBuilder` (automatic breadcrumbs), lets the UI drop tagged
//           POIs, and saves the ARWorldMap + map JSON through `MapStore`.
// Frames:   While scanning, the ARKit WORLD frame IS the map frame (origin = where the session
//           started), so camera positions are used as node positions directly.
// Threading: ARSession delivers delegate callbacks on the MAIN queue by default, and the
//           @Published properties are only touched there. Do not move the delegate queue
//           without adding hops.
// Live scan: besides breadcrumbs, about once a second it samples the LiDAR mesh (MeshSampler), fits a
//           gravity-aligned `OrientedBox` (the scan bounding box shown by LiveScanView) and publishes mesh
//           stats. The user can grow/shrink the box with `adjustBoxMargin`.
// Status:   SCAFFOLD - works end-to-end on paper; needs device testing. TODO(A):
//             * hold-still hint when worldMappingStatus != .mapped
//             * segment rollover (new segmentId every ~30 m) - Architecture.md 4.2
//           Extension: loads a chosen saved world map, waits for normal tracking, then asks
//           for explicit attachment near an existing corridor. Initial world map restores
//           the original MAP frame; never fall back to a fresh session origin for extensions.
//           UNVERIFIED ON DEVICE: alignment, linking, and cross-phone extension.
// Test on:  physical Pro iPhone only.
//
import ARKit
import SceneKit
import Combine
import WaypointCore

final class CaptureController: NSObject, ObservableObject, ARSessionDelegate {

    // MARK: Published UI state
    @Published private(set) var isRunning = false
    @Published private(set) var nodeCount = 0
    @Published private(set) var mappingStatus: ARFrame.WorldMappingStatus = .notAvailable
    @Published private(set) var trackingSummary = "Not started"
    @Published private(set) var savedMap: BuildingMap?
    @Published private(set) var extensionStatus: String?
    @Published private(set) var canRecord = false
    /// 0...1: how much of the walk has been seen from BOTH directions. A map scanned one way only
    /// relocalizes badly when the user comes back the other way (D-043).
    @Published private(set) var returnCoverage: Float = 0
    /// True once enough has been walked to judge and the coverage is still low.
    @Published private(set) var shouldWalkBack = false
    @Published var errorMessage: String?

    // Live-scan stats and bounding box (updated ~1 Hz)
    @Published private(set) var scanBox: OrientedBox?
    @Published private(set) var triangleCount = 0
    @Published private(set) var meshAnchorCount = 0
    /// Extra meters added to every side of the fitted box (user adjustable).
    @Published private(set) var boxMargin: Float = 0.1
    private var fittedBox: OrientedBox?
    private var lastBoxUpdate: TimeInterval = 0

    // Performance telemetry (shown in the console `scan:` line) and the mesh-overlay switch.
    @Published private(set) var fps: Double = 0
    @Published private(set) var lastFitMs: Double = 0
    /// Draw the live mesh over the camera. Turning it off does NOT stop mapping or lose anything: ARKit keeps building the same mesh and
    /// world map, and the HUD numbers and bounding box keep updating; only the GPU work of drawing every triangle each frame stops.
    /// Recording is paused: no breadcrumbs, no tags, no mesh counting, no box refit, no coverage. The AR session keeps TRACKING (pausing it would
    /// lose the map's origin), so resuming is seamless. See `pauseRecording` / `resumeRecording`.
    /// Progress of the 3D model export that follows a save: nil (nothing), "Building 3D model…", "3D model saved (12.3 MB)", or an error sentence.
    @Published private(set) var modelStatus: String?
    @Published private(set) var isPaused = false
    /// "Unscanned areas" overlay (yellow tiles on the box faces where no mesh exists yet). Off by default; turning it on costs one background pass per second.
    @Published var showCoverage = CaptureController.launchFlag("scanCoverage", default: false)
    /// The yellow "unscanned areas" tiles (named `gaps` so it does not collide with U2's `coverage` = how much was walked BOTH ways)
    @Published private(set) var gaps: CoverageSnapshot?
    private var pausedAt: SIMD3<Float>?
    @Published var showMeshOverlay: Bool = CaptureController.launchFlag("scanOverlay", default: true)
    private var framesSinceStatus = 0
    private var lastStatusTime: TimeInterval = 0
    private var isFitting = false
    private let boundsQueue = DispatchQueue(label: "waypoint.scan.bounds", qos: .userInitiated)

    /// Reads a Bool launch argument such as `-scanOverlay NO` (UserDefaults argument domain); `default` when absent.
    static func launchFlag(_ name: String, default fallback: Bool) -> Bool {
        UserDefaults.standard.object(forKey: name) == nil ? fallback : UserDefaults.standard.bool(forKey: name)
    }

    // MARK: Collaborators
    let session = ARSession()
    private let store: MapStore
    private let deviceName: String
    private var builder: MapBuilder?
    private var segmentId = "seg1"
    private var isExtension = false
    private var extensionAttached = false
    /// Session (ARKit world) -> MAP. IDENTITY when ARKit relocalized into the saved world map, because
    /// then the session's world frame IS the map frame. When the volunteer locates themselves by hand
    /// instead (`confirmPlace`), this carries their alignment, and EVERY position that becomes a map
    /// node must go through `mapPoint` / `mapDirection` - a node written in session coordinates would
    /// land in the wrong part of the building.
    private var worldToMap = matrix_identity_float4x4
    /// Places the volunteer has confirmed standing at. Two are needed: one fixes position only, and
    /// without ARKit's relocalization the session's yaw bears no relation to the map's.
    private var confirmedPlaces: [(map: SIMD3<Float>, world: SIMD3<Float>)] = []
    /// How many places have been confirmed so far (0, 1), for the UI.
    @Published private(set) var confirmedPlaceCount = 0
    /// The volunteer located themselves by hand, so ARKit does not have to recognise the space.
    private var alignedByHand = false
    /// A save is in flight. Published and readable so `LiveScanService` can tell "still working" from
    /// "stalled" instead of failing the save on a fixed timer.
    @Published private(set) var isSaving = false
    private var exportProbeDone = false
    private var latestCameraTransform: simd_float4x4?

    var needsExtensionAttachment: Bool { isExtension && !extensionAttached && isRunning }

    init(store: MapStore, deviceName: String) {
        self.store = store
        self.deviceName = deviceName
        super.init()
        session.delegate = self
    }

    // MARK: Control

    /// - Parameter recordSurfaceLabels: record ARKit's per-face surface classification (wall, floor, ceiling, door, window, table, seat).
    ///   It cannot be added to a scan afterwards, so it is ON by default for any scan you keep; turn it off only for quick tests or lag A/B runs.
    ///   `nil` = read the launch flag `-scanClassification YES/NO` (default YES).
    /// True while an existing scan is being read and decoded before the camera starts (extend only).
    @Published private(set) var isPreparing = false
    /// The decoded world map, handed back to `start` by `prepareExtension`.
    private var preparedExtension: ARWorldMap?
    /// Visual fingerprints collected during this scan; written into the map on save.
    private var keyframes: [Keyframe] = []
    /// One visual fingerprint attempt at a time, and no more often than this. It used to be tried on
    /// EVERY frame (60 Hz), doing Vision work plus a linear scan inside the capture loop - the prime
    /// suspect for the degraded scans seen after it was added (2026-10-17).
    private static let keyframeAttemptInterval: TimeInterval = 0.5
    private var lastKeyframeAttempt: TimeInterval = -.greatestFiniteMagnitude
    /// Has the space been walked both ways? (CoverageTracker, WaypointCore.)
    private var coverage = CoverageTracker()
    /// A few samples a second is plenty to fill 2 m cells.
    private static let coverageSampleInterval: TimeInterval = 0.25
    private var lastCoverageSample: TimeInterval = -.greatestFiniteMagnitude
    /// One feature print at a time: they are cheap but not free, and frames arrive at 60 Hz.
    private var isMakingKeyframe = false

    /// Reads and decodes the segment's world map off the main thread, then calls `done` on the main
    /// one. Any failure is reported in `errorMessage` and `done` is not called.
    private func prepareExtension(map: BuildingMap, initialSegment: String?,
                                  done: @escaping () -> Void) {
        isPreparing = true
        errorMessage = nil
        extensionStatus = "Opening the saved scan..."
        let store = self.store
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var decoded: ARWorldMap?
            var failure: String?
            do {
                try MapBundle(map: map).validate()
                if let initialSegment, map.segmentIds.contains(initialSegment),
                   let bytes = try store.loadWorldMap(mapId: map.id, segmentId: initialSegment) {
                    decoded = try NSKeyedUnarchiver.unarchivedObject(ofClass: ARWorldMap.self, from: bytes)
                }
                if decoded == nil {
                    failure = "This scan segment has no saved world map. Download its scan files or choose another segment."
                }
            } catch {
                failure = "Cannot extend this map: \(error.localizedDescription)"
            }
            DispatchQueue.main.async {
                guard let self, self.isPreparing else { return }
                if let failure {
                    self.isPreparing = false
                    self.extensionStatus = nil
                    self.errorMessage = failure
                    return
                }
                self.preparedExtension = decoded
                done()
            }
        }
    }

    func start(mapName: String, recordSurfaceLabels: Bool? = nil,
               extending map: BuildingMap? = nil, initialSegment: String? = nil) {
        guard ARWorldTrackingConfiguration.isSupported else {
            errorMessage = "ARKit world tracking is not supported on this device."
            return
        }
        modelStatus = nil
        let config = ARWorldTrackingConfiguration()
        // A failed/missing world map must never silently create an unaligned extension.
        // Reading and decoding one is slow (tens of megabytes through NSKeyedUnarchiver), so when
        // EXTENDING we do it on a background queue and re-enter here with the result, rather than
        // freezing the screen on the tap (device report 2026-10-17).
        if let map {
            guard let prepared = preparedExtension else {
                prepareExtension(map: map, initialSegment: initialSegment) { [weak self] in
                    guard let self, self.isPreparing else { return } // cancelled meanwhile
                    self.start(mapName: mapName, recordSurfaceLabels: recordSurfaceLabels,
                               extending: map, initialSegment: initialSegment)
                }
                return
            }
            preparedExtension = nil
            isPreparing = false
            config.initialWorldMap = prepared
        }
        isExtension = map != nil
        keyframes = []
        isMakingKeyframe = false
        lastKeyframeAttempt = -.greatestFiniteMagnitude
        coverage.reset()
        returnCoverage = 0
        shouldWalkBack = false
        lastCoverageSample = -.greatestFiniteMagnitude
        isSaving = false
        extensionAttached = false
        // A new capture starts unaligned: the session frame is the map frame only once ARKit has
        // relocalized, or once the volunteer has confirmed two places.
        worldToMap = matrix_identity_float4x4
        confirmedPlaces = []
        confirmedPlaceCount = 0
        alignedByHand = false
        segmentId = "seg_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        builder = MapBuilder(map: map ?? BuildingMap(name: mapName), segmentId: segmentId, deviceName: deviceName)
        nodeCount = map?.nodes.count ?? 0
        canRecord = false
        latestCameraTransform = nil
        errorMessage = nil
        mappingStatus = .notAvailable
        extensionStatus = isExtension ? "Find the selected scanned area. Move slowly until tracking recovers." : nil
        savedMap = nil
        scanBox = nil
        fittedBox = nil
        fps = 0
        lastFitMs = 0
        triangleCount = 0
        meshAnchorCount = 0
        lastBoxUpdate = 0

        // LiDAR mesh improves tracking/mapping quality; only available on Pro iPhones.
        // Surface classification (wall/floor/door...) costs extra on-device compute, but a scan recorded WITHOUT it can never get those labels
        // later (decision D-020, updated), so it is ON by default and switchable on the start screen / with `-scanClassification NO`.
        // Plane detection stays off: no code uses plane anchors, so nothing is lost.
        let wantClassification = recordSurfaceLabels ?? Self.launchFlag("scanClassification", default: true)
        if wantClassification, ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification) {
            config.sceneReconstruction = .meshWithClassification
        } else if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            config.sceneReconstruction = .mesh
        }
        config.planeDetection = []
        config.environmentTexturing = .none // saves memory/power; we never render reflections
        session.run(config, options: [.resetTracking, .removeExistingAnchors])
        isRunning = true
        Log.capture.info("capture started: \(mapName) | surfaceLabels=\(config.sceneReconstruction == .meshWithClassification)")
    }

    /// Tracks whether the space has been walked in BOTH directions. ARKit's relocalization matches
    /// what the camera sees against what it saw while scanning, so a corridor walked once gives a
    /// returning user almost nothing to match (device report 2026-10-17). Cheap: a dictionary insert
    /// a few times a second, no Vision, no allocation of consequence.
    private func updateCoverage(_ frame: ARFrame) {
        guard builder != nil, case .normal = frame.camera.trackingState else { return }
        guard frame.timestamp - lastCoverageSample >= Self.coverageSampleInterval else { return }
        lastCoverageSample = frame.timestamp

        let transform = frame.camera.transform
        let forward = Geometry.cameraForward(of: transform)
        coverage.observe(position: Geometry.translation(of: transform),
                         yaw: atan2(forward.x, -forward.z))
        // Same rule as the HUD values below: only publish real changes, this runs several times a second.
        let fraction = coverage.returnCoverage
        if abs(returnCoverage - fraction) > 0.01 { returnCoverage = fraction }
        let prompt = coverage.shouldPromptReturnWalk
        if shouldWalkBack != prompt { shouldWalkBack = prompt }
    }

    /// Records a visual fingerprint of this spot, at most one per `KeyframeRecorder.defaultSpacing`
    /// metres walked. The Vision work happens on a background queue; only the result comes back here.
    /// Skipped entirely while tracking is poor, because a keyframe whose pose we do not trust is worse
    /// than none - it would hand a returning user a confident wrong position.
    private func recordKeyframeIfDue(_ frame: ARFrame) {
        // Off unless the user has opted in, so recording and matching are enabled together (D-042).
        // Recording cost the scan something even though the matcher could never run.
        guard UIPrefs.visualFingerprintsEnabled,
              builder != nil, !isMakingKeyframe,
              case .normal = frame.camera.trackingState else { return }
        guard frame.timestamp - lastKeyframeAttempt >= Self.keyframeAttemptInterval else { return }
        lastKeyframeAttempt = frame.timestamp
        let position = Geometry.translation(of: frame.camera.transform)
        guard KeyframeIndex(keyframes: keyframes).shouldRecord(at: position,
                                                               spacing: KeyframeRecorder.defaultSpacing) else { return }

        isMakingKeyframe = true
        let pixelBuffer = frame.capturedImage
        let forward = Geometry.cameraForward(of: frame.camera.transform)
        let yaw = atan2(forward.x, -forward.z)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let descriptor = KeyframeRecorder.storableDescriptor(for: pixelBuffer, orientation: .right)
            DispatchQueue.main.async {
                guard let self else { return }
                self.isMakingKeyframe = false
                guard let descriptor else { return }
                self.keyframes.append(Keyframe(position: position, yaw: yaw, descriptor: descriptor))
            }
        }
    }

    func cancelPreparing() {
        isPreparing = false
        preparedExtension = nil
        extensionStatus = nil
    }

    /// Stops recording without stopping tracking. Idempotent.
    func pauseRecording() {
        guard isRunning, !isPaused else { return }
        isPaused = true
        pausedAt = latestCameraTransform.map { Geometry.translation(of: $0) }
        canRecord = false
        errorMessage = nil
    }

    /// Resumes recording, but only near where it was paused: otherwise the next breadcrumb would be joined to the last one by a straight edge
    /// through whatever lies between (see `ResumeGuard`). Returns false (and sets `errorMessage`) when refused.
    @discardableResult
    func resumeRecording() -> Bool {
        guard isPaused else { return true }
        let now = latestCameraTransform.map { Geometry.translation(of: $0) }
        guard ResumeGuard.canResume(pausedAt: pausedAt, now: now) else {
            if let a = pausedAt, let b = now { errorMessage = ResumeGuard.message(distance: Geometry.horizontalDistance(a, b)) }
            return false
        }
        errorMessage = nil
        isPaused = false
        pausedAt = nil
        return true
    }

    func stop() {
        isPaused = false
        pausedAt = nil
        gaps = nil
        isPreparing = false
        preparedExtension = nil
        session.pause()
        isRunning = false
        canRecord = false
        latestCameraTransform = nil
    }

    /// A point from the live session, in MAP coordinates.
    private func mapPoint(_ world: SIMD3<Float>) -> SIMD3<Float> { Geometry.transformPoint(worldToMap, world) }
    /// A direction from the live session, in MAP coordinates (rotation only, no translation).
    private func mapDirection(_ world: SIMD3<Float>) -> SIMD3<Float> { Geometry.transformDirection(worldToMap, world) }

    /// The labelled places in the map being extended, for the volunteer to pick from. Empty when this
    /// is not an extension.
    var placesToStandAt: [MapNode] {
        guard isExtension, let builder else { return [] }
        return builder.map.nodes
            .filter { ($0.label?.trimmingCharacters(in: .whitespaces).isEmpty == false) }
            .sorted { ($0.label ?? "") < ($1.label ?? "") }
    }

    /// "I am standing at this place." Needs TWO, a few metres apart: the first fixes where the session
    /// sits in the map, the second fixes which way it is turned. When the second arrives the alignment
    /// is solved and the extension attaches straight away, so ARKit never has to recognise the space.
    ///
    /// Refuses rather than guesses: see `ManualAlignment`. A wrong alignment writes every new node into
    /// the wrong part of the building, which is much worse than asking the volunteer to try again.
    func confirmPlace(_ node: MapNode) {
        // Deliberately NOT gated on `.normal` tracking. While extending, the saved world map is loaded, so
        // ARKit sits in `.limited(.relocalizing)` hunting for a space it may never recognise - which is the
        // exact situation this feature exists to escape. Requiring `.normal` made it unreachable. ARKit is
        // still tracking its own provisional frame meanwhile, and that frame is all the alignment needs,
        // because both confirmed places are measured in it.
        guard isExtension, !extensionAttached, isRunning, !isSaving,
              let frame = session.currentFrame else {
            extensionStatus = "Hold the phone up so the camera can see, then confirm the place again."
            return
        }
        if case .limited(.initializing) = frame.camera.trackingState {
            extensionStatus = "Still starting the camera. Give it a second, then confirm the place again."
            return
        }
        let world = Geometry.translation(of: frame.camera.transform)
        guard let first = confirmedPlaces.first else {
            confirmedPlaces = [(map: node.position, world: world)]
            confirmedPlaceCount = 1
            extensionStatus = "Got it. Now walk to another labelled place at least \(Int(ManualAlignment.minSeparationMeters)) meters away and confirm that one."
            Log.capture.info("alignment: first place \(node.label ?? "-")")
            return
        }
        switch ManualAlignment.worldToMap(mapA: first.map, worldA: first.world,
                                          mapB: node.position, worldB: world) {
        case .failure(.tooClose):
            extensionStatus = "Those two places are too close together to tell which way you are facing. Pick one further away."
        case .failure(.lengthMismatch(let mapMeters, let walked)):
            extensionStatus = String(format: "That does not add up: the map puts those places %.0f m apart but you walked %.0f m. Start again from the first place.", mapMeters, walked)
            confirmedPlaces = []
            confirmedPlaceCount = 0
        case .failure(.notFinite):
            extensionStatus = "Lost track of where you walked. Start again from the first place."
            confirmedPlaces = []
            confirmedPlaceCount = 0
        case .success(let transform):
            worldToMap = transform
            alignedByHand = true
            confirmedPlaceCount = 2
            Log.capture.info("alignment: solved from two places, yaw \(Geometry.yawAboutY(of: transform) * 180 / .pi) deg")
            beginExtension()
        }
    }

    /// Volunteer confirms they are in the mapped corridor after ARKit has relocalized.
    /// Starting a new segment never changes the world origin or any existing node.
    func beginExtension() {
        guard isExtension, !extensionAttached, isRunning, !isSaving,
              let frame = session.currentFrame, case .normal = frame.camera.trackingState,
              // A hand alignment IS the fix, so ARKit's own opinion of the saved map is irrelevant;
              // without one we still wait for it to have matched the space.
              alignedByHand || frame.worldMappingStatus == .mapped || frame.worldMappingStatus == .extending,
              let builder else {
            extensionStatus = "Still finding the saved area. Look around slowly, or confirm a labelled place you are standing at."
            return
        }
        guard builder.attachExtension(at: mapPoint(Geometry.translation(of: frame.camera.transform))) else {
            extensionStatus = "Move within 2 meters of a previously scanned corridor point on the same floor, then try again."
            return
        }
        extensionAttached = true
        canRecord = true
        nodeCount = builder.map.nodes.count
        extensionStatus = "Extending this building. Walk into the new area and tag rooms."
        Log.capture.info("extension attached: map=\(builder.map.id) segment=\(self.segmentId)")
    }

    /// Drops a tagged node ~1 m in front of the camera (on the floor plane of the camera height).
    func tagPOI(kind: NodeKind, label: String?) {
        guard canRecord, let builder, let t = latestCameraTransform else { return }
        let pos = Geometry.translation(of: t)
        var fwd = Geometry.cameraForward(of: t)
        fwd.y = 0
        let ahead = simd_length(fwd) > 1e-3 ? simd_normalize(fwd) : SIMD3<Float>(0, 0, -1)
        // `roomExtent` samples the LIVE mesh, so it must be seeded with the session position and its
        // result carried into the map frame afterwards; everything stored on the node is map frame.
        let extent = kind == .room ? roomExtent(standingAt: pos)?.transformed(by: worldToMap) : nil
        let node = builder.addPOI(kind: kind, label: label, position: mapPoint(pos + ahead),
                                  extent: extent)
        nodeCount = builder.map.nodes.count
        let area = node.extent.map { String(format: " (%.0f m2)", $0.areaSquareMeters) } ?? ""
        Log.capture.info("tagged \(node.kind.rawValue) \(node.label ?? "-")\(area)")
    }

    /// Works out the floor area of the room the volunteer is standing in, from the WALL faces of the
    /// live mesh (RoomExtractor). nil when the space is not enclosed, when classification is off, or
    /// on a phone that cannot classify - guidance then falls back to a plain arrival radius.
    /// Runs on the main thread at the moment of a tap, on a bounded slice of the mesh, so the cost is
    /// a one-off rather than per frame.
    private func roomExtent(standingAt position: SIMD3<Float>) -> RoomExtent? {
        guard let frame = session.currentFrame else { return nil }
        let anchors = frame.anchors.compactMap { $0 as? ARMeshAnchor }
        guard !anchors.isEmpty else { return nil }

        let points = MeshSampler.wallPoints(anchors: anchors, seed: position,
                                            radius: RoomExtractor.defaultMaxRadius)
        guard !points.isEmpty else {
            Log.capture.info("room extent: no classified wall faces nearby (classification off?)")
            return nil
        }
        guard let result = RoomExtractor.extract(seed: position, wallPoints: points, floorY: position.y - eyeHeight) else {
            Log.capture.info("room extent: no enclosing walls found; falling back to a radius")
            return nil
        }
        Log.capture.info(String(format: "room extent: %.1f x %.1f m, %.0f m2 enclosed",
                                result.extent.halfExtents.x * 2, result.extent.halfExtents.y * 2,
                                result.areaSquareMeters))
        return result.extent
    }

    /// Rough height of the camera above the floor while someone walks holding a phone. Used only to
    /// put the room's extent at floor level rather than at chest level.
    private let eyeHeight: Float = 1.4

    /// Grows (+) or shrinks (-) the scan box on every side, clamped to 0...2 m. Applies immediately.
    func adjustBoxMargin(by delta: Float) {
        boxMargin = min(2, max(0, boxMargin + delta))
        scanBox = fittedBox?.expanded(by: boxMargin)
    }

    /// Saves map JSON + ARWorldMap. Disabled in the UI until `mappingStatus == .mapped`.
    func save() {
        guard canRecord, mappingStatus == .mapped, let builder else { return }
        var map = builder.map
        map.keyframes += keyframes
        Log.capture.info("saving \(self.keyframes.count) keyframe(s)")
        let savedSegment = segmentId
        // Freeze acquisition while obtaining the world map so JSON and scan bytes describe
        // the same capture. Tracking telemetry continues until the save completes.
        canRecord = false
        isSaving = true
        // Snapshot the mesh now (before stop() pauses the session) for the 3D model export that follows the save.
        let meshAnchors = session.currentFrame?.anchors.compactMap { $0 as? ARMeshAnchor } ?? []
        let exportBox = scanBox
        session.getCurrentWorldMap { [weak self] worldMap, error in
            guard let self else { return }
            // The heavy part runs OFF the main thread. Archiving a tens-of-megabytes ARWorldMap and
            // writing it to disk took many seconds on a big scan, and doing it on the main queue froze
            // the whole UI meanwhile - which is also why the old fixed save deadline kept expiring: the
            // timer could not even fire until the work it was timing had finished (device report
            // 2026-10-18). Only the published results go back to the main queue.
            DispatchQueue.global(qos: .userInitiated).async {
                guard let worldMap else {
                    DispatchQueue.main.async {
                        self.isSaving = false
                        guard self.isRunning else { return }
                        self.errorMessage = "Could not capture world map: \(error?.localizedDescription ?? "unknown")"
                    }
                    return
                }
                do {
                    let data = try NSKeyedArchiver.archivedData(withRootObject: worldMap, requiringSecureCoding: true)
                    // Merge against the latest local copy so a download arriving during capture
                    // cannot be erased by saving this older starting snapshot.
                    // saveLocalScan, not importBundle: a long scan's ARWorldMap can exceed the 50 MB SHARING limit and must still be saved on the phone.
                    let saved = try self.store.saveLocalScan(map: map, worldMap: data, segmentId: savedSegment)
                    DispatchQueue.main.async {
                        self.isSaving = false
                        guard self.isRunning else { return }
                        self.savedMap = saved
                        self.exportModel(anchors: meshAnchors, box: exportBox, mapId: saved.id)
                        self.stop()
                        Log.capture.info("saved map \(map.name) nodes=\(map.nodes.count) worldmap=\(data.count) bytes")
                    }
                } catch {
                    DispatchQueue.main.async {
                        self.isSaving = false
                        guard self.isRunning else { return }
                        self.errorMessage = "Save failed: \(error.localizedDescription)"
                    }
                }
            }
        }
    }

    /// Builds the 3D model (USDZ) next to the saved map on a background queue. A failure never affects the saved map.
    private func exportModel(anchors: [ARMeshAnchor], box: OrientedBox?, mapId: UUID) {
        guard !anchors.isEmpty else { modelStatus = nil; return }
        modelStatus = "Building 3D model…"
        let url = store.modelURL(mapId: mapId)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let message: String
            do {
                let report = try MeshExporter.export(anchors: anchors, box: box, to: url)
                let size = ByteCountFormatter.string(fromByteCount: Int64(report.fileBytes), countStyle: .file)
                message = "3D model saved (\(size), \(report.triangles.formatted()) triangles)"
                Log.capture.info("model exported: \(report.fileBytes) bytes, \(report.triangles) triangles, cell=\(report.clusterCellSize.map { String($0) } ?? "none"), fits=\(report.fitsBudget)")
            } catch {
                message = "3D model not saved: \(error.localizedDescription)"
                Log.capture.error("model export failed: \(error.localizedDescription)")
            }
            DispatchQueue.main.async { self?.modelStatus = message }
        }
    }

    // MARK: ARSessionDelegate

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        latestCameraTransform = frame.camera.transform
        updateCoverage(frame)
        recordKeyframeIfDue(frame)
        // PERFORMANCE (lossless): assigning an @Published property re-renders the SwiftUI screen even when the value is unchanged, and this
        // runs ~60x per second. Only publish real changes.
        if mappingStatus != frame.worldMappingStatus { mappingStatus = frame.worldMappingStatus }
        let summary = Self.describe(frame.camera.trackingState)
        if trackingSummary != summary { trackingSummary = summary }
        framesSinceStatus += 1

        if frame.timestamp - lastBoxUpdate >= 1.0 {
            let elapsed = frame.timestamp - lastBoxUpdate
            lastBoxUpdate = frame.timestamp
            let newFps = lastStatusTime > 0 && elapsed > 0 ? Double(framesSinceStatus) / elapsed : 0
            framesSinceStatus = 0
            lastStatusTime = frame.timestamp
            if abs(newFps - fps) > 0.5 { fps = newFps }
            if !isPaused { updateScanBox(from: frame) }
            // Headless check (`-scanExportProbe YES`, with -autoScan): once there is a real mesh, export it exactly as a save would, log the
            // result and delete the file. Proves ARMeshAnchor extraction + decimation + USDZ writing on real LiDAR data without walking.
            if !exportProbeDone, Self.launchFlag("scanExportProbe", default: false), triangleCount > 3000 {
                exportProbeDone = true
                let anchors = frame.anchors.compactMap { $0 as? ARMeshAnchor }
                let box = scanBox
                DispatchQueue.global(qos: .utility).async {
                    let url = FileManager.default.temporaryDirectory.appendingPathComponent("probe-\(UUID().uuidString).usdz")
                    defer { try? FileManager.default.removeItem(at: url) }
                    let started = CACurrentMediaTime()
                    do {
                        let r = try MeshExporter.export(anchors: anchors, box: box, to: url)
                        let scene = try? SCNScene(url: url, options: nil)
                        var back = 0
                        scene?.rootNode.enumerateHierarchy { node, _ in for e in node.geometry?.elements ?? [] { back += e.primitiveCount } }
                        Log.capture.info("EXPORT PROBE PASS: \(anchors.count) anchors -> \(r.triangles) triangles (read back \(back)), \(r.fileBytes) bytes, cell=\(r.clusterCellSize.map { String($0) } ?? "none"), fits=\(r.fitsBudget), \(Int((CACurrentMediaTime() - started) * 1000)) ms")
                    } catch {
                        Log.capture.error("EXPORT PROBE FAIL: \(error.localizedDescription)")
                    }
                }
            }
            let box = scanBox.map { String(format: "%.1fx%.1fx%.1f", $0.size.x, $0.size.y, $0.size.z) } ?? "none"
            Log.capture.info("scan: \(trackingSummary) | mapping=\(mappingStatus.rawValue) | nodes=\(nodeCount) | meshAnchors=\(meshAnchorCount) | triangles=\(triangleCount) | box=\(box) | posture pitch=\(Int(PostureMonitor.reading(cameraTransform: frame.camera.transform).pitchDegrees)) roll=\(Int(PostureMonitor.reading(cameraTransform: frame.camera.transform).rollDegrees)) | fps=\(String(format: "%.0f", fps)) | fitMs=\(String(format: "%.1f", lastFitMs)) | overlay=\(showMeshOverlay) | gaps=\(gaps.map { String(format: "%.0f%% (%d open tiles, %d outline dashes)", $0.percent * 100, $0.tiles.count, $0.outline.count) } ?? "off") | paused=\(isPaused)")
        }

        // Only record while tracking is good, otherwise breadcrumbs would be placed wrongly.
        guard isRunning, savedMap == nil, !isSaving else { return }
        guard !isPaused else { if canRecord { canRecord = false }; return }
        guard case .normal = frame.camera.trackingState else {
            if canRecord { canRecord = false }
            return
        }
        let ready = !isExtension || extensionAttached
        if canRecord != ready { canRecord = ready }
        guard canRecord, let builder else { return }
        if builder.observe(position: mapPoint(Geometry.translation(of: frame.camera.transform))) != nil {
            nodeCount = builder.map.nodes.count
        }
    }

    /// Measures the mesh and refits the bounding box OFF the main thread. If the previous fit is still running this tick is skipped
    /// (the next one reads a newer mesh anyway), so slow fits can never stack up and stall the UI or AR callbacks.
    private func updateScanBox(from frame: ARFrame) {
        let anchors = frame.anchors.compactMap { $0 as? ARMeshAnchor } // immutable snapshots; safe to read on another queue
        guard !anchors.isEmpty, !isFitting else { return }
        isFitting = true
        let wantCoverage = showCoverage, margin = boxMargin
        boundsQueue.async { [weak self] in
            let start = CACurrentMediaTime()
            let measurement = MeshSampler.measure(anchors: anchors)
            let box = OrientedBox.fitBest(hull: measurement.hull, minY: measurement.minY, maxY: measurement.maxY)
            // Coverage grid over the (margin-expanded) box, only when the overlay is on.
            var snapshot: CoverageSnapshot?
            if wantCoverage, let shown = box?.expanded(by: margin) {
                var grid = CoverageGrid(box: shown)
                grid.add(points: MeshSampler.samplePoints(anchors: anchors))
                snapshot = CoverageSnapshot(tiles: grid.uncoveredTiles(), outline: CoverageGrid.dashed(grid.outline()), percent: grid.coverage)
            }
            let ms = (CACurrentMediaTime() - start) * 1000
            DispatchQueue.main.async {
                guard let self else { return }
                self.isFitting = false
                self.lastFitMs = ms
                if self.triangleCount != measurement.triangleCount { self.triangleCount = measurement.triangleCount }
                if self.meshAnchorCount != measurement.anchorCount { self.meshAnchorCount = measurement.anchorCount }
                self.fittedBox = box
                if wantCoverage { self.gaps = snapshot } else if self.gaps != nil { self.gaps = nil }
                let shown = box?.expanded(by: self.boxMargin)
                if self.scanBox != shown { self.scanBox = shown }
            }
        }
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        errorMessage = "AR session failed: \(error.localizedDescription)"
        stop()
    }

    static func describe(_ state: ARCamera.TrackingState) -> String {
        switch state {
        case .normal: return "Tracking OK"
        case .notAvailable: return "Tracking unavailable"
        case .limited(let reason):
            switch reason {
            case .initializing: return "Initializing - move the phone slowly"
            case .excessiveMotion: return "Moving too fast"
            case .insufficientFeatures: return "Not enough detail in view"
            case .relocalizing: return "Relocalizing"
            @unknown default: return "Limited tracking"
            }
        }
    }
}

/// What the "unscanned areas" overlay draws: yellow tiles, a dashed white outline, and the coverage figure for the HUD.
struct CoverageSnapshot: Equatable {
    var tiles: [UncoveredTile]
    var outline: [CoverageSegment]
    /// 0...1
    var percent: Float
}
