//
// File:     Waypoint/Relocalization/Relocalizer.swift
// Owner:    A (AR/Maps)
// Purpose:  Navigator mode ARSession wrapper. Re-finds the user inside a saved map in TWO ways:
//             1. PRIMARY  - load the saved ARWorldMap as `initialWorldMap`; ARKit relocalizes when
//                           it recognises the space. When tracking becomes .normal we are
//                           localized and map frame == world frame (`mapToWorld` = identity).
//             2. FALLBACK - if the map has a `MarkerRef` and the app bundle has the matching
//                           reference image, seeing the marker gives an `ARImageAnchor`; we then
//                           compute `mapToWorld` from it (WaypointCore `MarkerRef`).
//           Everything downstream (NavigationController) converts with `mapToWorld`.
// Output:   `state` (@Published), `mapToWorld`, and the `onFrame` callback that forwards each
//           ARFrame to NavigationController (so there is exactly ONE ARSession delegate).
// Status:   SCAFFOLD. TODO(A):
//             * add reference images to an asset catalog group named "WaypointMarkers"
//               (until then `detectionImages` is nil and only the world-map path works)
//             * verify the marker yaw convention on a device (see Geometry.swift note)
//             * surface "move slowly / look around" coaching while .searching
// Test on:  physical Pro iPhone only. Walk the same hallway you scanned.
//
import ARKit
import Combine
import WaypointCore

final class Relocalizer: NSObject, ObservableObject, ARSessionDelegate {

    enum State: Equatable {
        case idle
        case searching   // session running, not yet recognised the space
        case localized   // tracking normal AND (world map matched OR marker seen)
        case lost        // was localized, tracking now limited/unavailable
    }

    @Published private(set) var state: State = .idle

    /// Converts MAP-frame points to ARKit WORLD-frame points: world = mapToWorld * map.
    /// Identity when relocalized via world map.
    private(set) var mapToWorld: simd_float4x4 = matrix_identity_float4x4

    /// Called for every ARFrame (main queue). Set by NavigationController.
    var onFrame: ((ARFrame) -> Void)?

    let session = ARSession()
    private var map: BuildingMap?
    private var usingWorldMap = false
    private var markerSeen = false

    override init() {
        super.init()
        session.delegate = self
    }

    func start(map: BuildingMap, store: MapStore) {
        self.map = map
        mapToWorld = matrix_identity_float4x4
        markerSeen = false
        state = .searching

        let config = ARWorldTrackingConfiguration()
        // sceneDepth feeds the obstacle detector (LiDAR depth per frame).
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            config.frameSemantics.insert(.sceneDepth)
        }
        // A labelled LiDAR mesh lets `ObstacleIdentifier` say "wall / door / table / chair" for what is in the way. Only on LiDAR phones.
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification) {
            config.sceneReconstruction = .meshWithClassification
        }

        // Primary path: saved world map for the first segment that has one.
        usingWorldMap = false
        for segment in map.segmentIds {
            if let data = try? store.loadWorldMap(mapId: map.id, segmentId: segment),
               let worldMap = try? NSKeyedUnarchiver.unarchivedObject(ofClass: ARWorldMap.self, from: data) {
                config.initialWorldMap = worldMap
                usingWorldMap = true
                Log.reloc.info("using world map for segment \(segment)")
                break // TODO(A): multi-segment stitching
            }
        }
        if !usingWorldMap { Log.reloc.info("no world map on disk; relying on marker or session origin") }

        // Fallback path: marker images (nil until the asset catalog group exists).
        if let images = ARReferenceImage.referenceImages(inGroupNamed: "WaypointMarkers", bundle: nil) {
            config.detectionImages = images
            config.maximumNumberOfTrackedImages = 1
        }

        session.run(config, options: [.resetTracking, .removeExistingAnchors])
    }

    func stop() {
        session.pause()
        state = .idle
    }

    // MARK: ARSessionDelegate

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        updateState(for: frame.camera.trackingState)
        onFrame?(frame)
    }

    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        guard let marker = map?.marker else { return }
        for case let anchor as ARImageAnchor in anchors where anchor.referenceImage.name == marker.name {
            mapToWorld = marker.mapToWorldTransform(markerWorld: anchor.transform)
            markerSeen = true
            state = .localized
            Log.reloc.info("aligned to marker \(marker.name)")
        }
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        Log.reloc.error("session failed: \(error.localizedDescription)")
        state = .lost
    }

    // MARK: Private

    private func updateState(for tracking: ARCamera.TrackingState) {
        switch tracking {
        case .normal:
            // With a world map, normal tracking means ARKit matched the space. Without one, only a
            // marker sighting makes the position meaningful.
            if usingWorldMap || markerSeen {
                if state != .localized { Log.reloc.info("localized") }
                state = .localized
            }
        case .limited(.relocalizing), .limited(.initializing):
            if state == .localized { state = .lost } else if state == .idle { state = .searching }
        default:
            if state == .localized { state = .lost }
        }
    }
}
