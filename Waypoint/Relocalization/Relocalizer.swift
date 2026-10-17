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

    /// True while the saved scan is being read off disk and decoded, BEFORE the camera session starts.
    /// An ARWorldMap is tens of megabytes and `NSKeyedUnarchiver` is not quick; doing it on the main
    /// thread froze the app for seconds after tapping Navigate (device report 2026-10-17).
    @Published private(set) var isPreparing = false

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

    /// Reads the saved scan on a BACKGROUND queue, then starts the camera session on the main one.
    /// Everything slow (file read, `NSKeyedUnarchiver`, loading the marker images out of the asset
    /// catalog) happens off the main thread; only `session.run` is left on it, which is required.
    func start(map: BuildingMap, store: MapStore) {
        self.map = map
        mapToWorld = matrix_identity_float4x4
        markerSeen = false
        usingWorldMap = false
        state = .searching
        isPreparing = true

        let mapId = map.id
        let segments = map.segmentIds

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // Primary path: saved world map for the first segment that has one.
            var loaded: ARWorldMap?
            var loadedSegment: String?
            for segment in segments {
                if let data = try? store.loadWorldMap(mapId: mapId, segmentId: segment),
                   let worldMap = try? NSKeyedUnarchiver.unarchivedObject(ofClass: ARWorldMap.self, from: data) {
                    loaded = worldMap
                    loadedSegment = segment
                    break // TODO(A): multi-segment stitching
                }
            }
            // Fallback path: marker images (nil until the asset catalog group exists).
            let markers = ARReferenceImage.referenceImages(inGroupNamed: "WaypointMarkers", bundle: nil)

            DispatchQueue.main.async {
                guard let self else { return }
                // Navigation may have been stopped while we were loading; do not grab the camera.
                guard self.isPreparing else {
                    Log.reloc.info("world map finished loading after stop; discarded")
                    return
                }
                self.runSession(worldMap: loaded, segment: loadedSegment, markers: markers)
            }
        }
    }

    private func runSession(worldMap: ARWorldMap?, segment: String?, markers: Set<ARReferenceImage>?) {
        let config = ARWorldTrackingConfiguration()
        // sceneDepth feeds the obstacle detector (LiDAR depth per frame).
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            config.frameSemantics.insert(.sceneDepth)
        }
        // A labelled LiDAR mesh lets `ObstacleIdentifier` say "wall / door / table / chair" for what is in the way. Only on LiDAR phones.
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification) {
            config.sceneReconstruction = .meshWithClassification
        }
        if let worldMap {
            config.initialWorldMap = worldMap
            usingWorldMap = true
            Log.reloc.info("using world map for segment \(segment ?? "?")")
        } else {
            Log.reloc.info("no world map on disk; relying on marker or session origin")
        }
        if let markers {
            config.detectionImages = markers
            config.maximumNumberOfTrackedImages = 1
        }

        session.run(config, options: [.resetTracking, .removeExistingAnchors])
        isPreparing = false
    }

    func stop() {
        isPreparing = false // also tells an in-flight load to discard itself
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
