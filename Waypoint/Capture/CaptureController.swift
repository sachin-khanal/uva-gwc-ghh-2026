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
    private var isSaving = false
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
        isSaving = false
        extensionAttached = false
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

    /// Records a visual fingerprint of this spot, at most one per `KeyframeRecorder.defaultSpacing`
    /// metres walked. The Vision work happens on a background queue; only the result comes back here.
    /// Skipped entirely while tracking is poor, because a keyframe whose pose we do not trust is worse
    /// than none - it would hand a returning user a confident wrong position.
    private func recordKeyframeIfDue(_ frame: ARFrame) {
        guard builder != nil, !isMakingKeyframe,
              case .normal = frame.camera.trackingState else { return }
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

    func stop() {
        isPreparing = false
        preparedExtension = nil
        session.pause()
        isRunning = false
        canRecord = false
        latestCameraTransform = nil
    }

    /// Volunteer confirms they are in the mapped corridor after ARKit has relocalized.
    /// Starting a new segment never changes the world origin or any existing node.
    func beginExtension() {
        guard isExtension, !extensionAttached, isRunning, !isSaving,
              let frame = session.currentFrame, case .normal = frame.camera.trackingState,
              frame.worldMappingStatus == .mapped || frame.worldMappingStatus == .extending,
              let builder else {
            extensionStatus = "Still finding the saved area. Look around slowly; recording is paused."
            return
        }
        guard builder.attachExtension(at: Geometry.translation(of: frame.camera.transform)) else {
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
        let node = builder.addPOI(kind: kind, label: label, position: pos + ahead,
                                  extent: kind == .room ? roomExtent(standingAt: pos) : nil)
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
        session.getCurrentWorldMap { [weak self] worldMap, error in
            guard let self else { return }
            DispatchQueue.main.async {
                defer { self.isSaving = false }
                guard self.isRunning else { return }
                guard let worldMap else {
                    self.errorMessage = "Could not capture world map: \(error?.localizedDescription ?? "unknown")"
                    return
                }
                do {
                    let data = try NSKeyedArchiver.archivedData(withRootObject: worldMap, requiringSecureCoding: true)
                    // Merge against the latest local copy so a download arriving during capture
                    // cannot be erased by saving this older starting snapshot.
                    let saved = try self.store.importBundle(MapBundle(map: map, worldMaps: [savedSegment: data]))
                    self.savedMap = saved
                    self.stop()
                    Log.capture.info("saved map \(map.name) nodes=\(map.nodes.count) worldmap=\(data.count) bytes")
                } catch {
                    self.errorMessage = "Save failed: \(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: ARSessionDelegate

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        latestCameraTransform = frame.camera.transform
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
            updateScanBox(from: frame)
            let box = scanBox.map { String(format: "%.1fx%.1fx%.1f", $0.size.x, $0.size.y, $0.size.z) } ?? "none"
            Log.capture.info("scan: \(trackingSummary) | mapping=\(mappingStatus.rawValue) | nodes=\(nodeCount) | meshAnchors=\(meshAnchorCount) | triangles=\(triangleCount) | box=\(box) | posture pitch=\(Int(PostureMonitor.reading(cameraTransform: frame.camera.transform).pitchDegrees)) roll=\(Int(PostureMonitor.reading(cameraTransform: frame.camera.transform).rollDegrees)) | fps=\(String(format: "%.0f", fps)) | fitMs=\(String(format: "%.1f", lastFitMs)) | overlay=\(showMeshOverlay)")
        }

        // Only record while tracking is good, otherwise breadcrumbs would be placed wrongly.
        guard isRunning, savedMap == nil, !isSaving else { return }
        guard case .normal = frame.camera.trackingState else {
            if canRecord { canRecord = false }
            return
        }
        let ready = !isExtension || extensionAttached
        if canRecord != ready { canRecord = ready }
        guard canRecord, let builder else { return }
        if builder.observe(position: Geometry.translation(of: frame.camera.transform)) != nil {
            nodeCount = builder.map.nodes.count
        }
    }

    /// Measures the mesh and refits the bounding box OFF the main thread. If the previous fit is still running this tick is skipped
    /// (the next one reads a newer mesh anyway), so slow fits can never stack up and stall the UI or AR callbacks.
    private func updateScanBox(from frame: ARFrame) {
        let anchors = frame.anchors.compactMap { $0 as? ARMeshAnchor } // immutable snapshots; safe to read on another queue
        guard !anchors.isEmpty, !isFitting else { return }
        isFitting = true
        boundsQueue.async { [weak self] in
            let start = CACurrentMediaTime()
            let measurement = MeshSampler.measure(anchors: anchors)
            let box = OrientedBox.fitBest(hull: measurement.hull, minY: measurement.minY, maxY: measurement.maxY)
            let ms = (CACurrentMediaTime() - start) * 1000
            DispatchQueue.main.async {
                guard let self else { return }
                self.isFitting = false
                self.lastFitMs = ms
                if self.triangleCount != measurement.triangleCount { self.triangleCount = measurement.triangleCount }
                if self.meshAnchorCount != measurement.anchorCount { self.meshAnchorCount = measurement.anchorCount }
                self.fittedBox = box
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
