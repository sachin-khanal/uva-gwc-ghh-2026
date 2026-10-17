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
// Status:   SCAFFOLD - works end-to-end on paper; needs device testing. TODO(A):
//             * hold-still hint when worldMappingStatus != .mapped
//             * segment rollover (new segmentId every ~30 m) - Architecture.md 4.2
//             * "extend existing map": load map + relocalize first, then keep recording
//               (MapBuilder must then link its first breadcrumb to the nearest existing node)
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
    @Published var errorMessage: String?

    // MARK: Collaborators
    let session = ARSession()
    private let store: MapStore
    private let deviceName: String
    private var builder: MapBuilder?
    private let segmentId = "seg1"
    private var latestCameraTransform: simd_float4x4?

    init(store: MapStore, deviceName: String) {
        self.store = store
        self.deviceName = deviceName
        super.init()
        session.delegate = self
    }

    // MARK: Control

    func start(mapName: String) {
        guard ARWorldTrackingConfiguration.isSupported else {
            errorMessage = "ARKit world tracking is not supported on this device."
            return
        }
        builder = MapBuilder(map: BuildingMap(name: mapName), segmentId: segmentId, deviceName: deviceName)
        nodeCount = 0
        savedMap = nil

        let config = ARWorldTrackingConfiguration()
        // LiDAR mesh improves tracking/mapping quality; only available on Pro iPhones.
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            config.sceneReconstruction = .mesh
        }
        config.planeDetection = [.horizontal, .vertical]
        config.environmentTexturing = .none // saves memory/power; we never render reflections
        session.run(config, options: [.resetTracking, .removeExistingAnchors])
        isRunning = true
        Log.capture.info("capture started: \(mapName)")
    }

    func stop() {
        session.pause()
        isRunning = false
    }

    /// Drops a tagged node ~1 m in front of the camera (on the floor plane of the camera height).
    func tagPOI(kind: NodeKind, label: String?) {
        guard let builder, let t = latestCameraTransform else { return }
        let pos = Geometry.translation(of: t)
        var fwd = Geometry.cameraForward(of: t)
        fwd.y = 0
        let ahead = simd_length(fwd) > 1e-3 ? simd_normalize(fwd) : SIMD3<Float>(0, 0, -1)
        let node = builder.addPOI(kind: kind, label: label, position: pos + ahead)
        nodeCount = builder.map.nodes.count
        Log.capture.info("tagged \(node.kind.rawValue) \(node.label ?? "-")")
    }

    /// Saves map JSON + ARWorldMap. Disabled in the UI until `mappingStatus == .mapped`.
    func save() {
        guard let builder else { return }
        let map = builder.map
        session.getCurrentWorldMap { [weak self] worldMap, error in
            guard let self else { return }
            guard let worldMap else {
                self.errorMessage = "Could not capture world map: \(error?.localizedDescription ?? "unknown")"
                return
            }
            do {
                let data = try NSKeyedArchiver.archivedData(withRootObject: worldMap, requiringSecureCoding: true)
                try self.store.saveWorldMap(data, mapId: map.id, segmentId: self.segmentId)
                try self.store.save(map)
                self.savedMap = map
                Log.capture.info("saved map \(map.name) nodes=\(map.nodes.count) worldmap=\(data.count) bytes")
            } catch {
                self.errorMessage = "Save failed: \(error.localizedDescription)"
            }
        }
    }

    // MARK: ARSessionDelegate

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        latestCameraTransform = frame.camera.transform
        mappingStatus = frame.worldMappingStatus
        trackingSummary = Self.describe(frame.camera.trackingState)

        // Only record while tracking is good, otherwise breadcrumbs would be placed wrongly.
        guard case .normal = frame.camera.trackingState, let builder else { return }
        if builder.observe(position: Geometry.translation(of: frame.camera.transform)) != nil {
            nodeCount = builder.map.nodes.count
        }
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        errorMessage = "AR session failed: \(error.localizedDescription)"
        isRunning = false
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
