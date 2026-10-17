//
// File:     Waypoint/Scan/LiveScanView.swift
// Owner:    A (AR/Maps)
// Purpose:  The Polycam-style live scan view: the camera feed with the LiDAR mesh drawn over it as it
//           grows, plus a green wireframe BOUNDING BOX around the scanned space.
//             * Mesh overlay: RealityKit's built-in `.showSceneUnderstanding` debug option (fastest path to a
//               working live mesh). TODO(A): replace with one ModelEntity per ARMeshAnchor coloured by
//               ARMeshClassification (floor/wall/door/...) for a nicer look and for exporting.
//             * Box: 12 thin green bars rebuilt whenever `box` changes (cheap: 12 entities, ~1 Hz).
// Session:  The view renders the `ARSession` owned by CaptureController (it does NOT start its own:
//           `automaticallyConfigureSession = false`). The controller remains the session delegate.
// Status:   SCAFFOLD, UNVERIFIED ON DEVICE.
//
import ARKit
import RealityKit
import SwiftUI
import WaypointCore

struct LiveScanView: UIViewRepresentable {

    let session: ARSession
    let box: OrientedBox?
    /// false = no mesh overlay (cheapest). Mapping continues either way. Defaults to true so older call sites `LiveScanView(session:box:)`
    /// (e.g. the new Scanner flow on branch app-ui-workflows) still compile.
    var showMesh: Bool = true

    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero)
        view.automaticallyConfigureSession = false
        view.session = session
        view.debugOptions = showMesh ? [.showSceneUnderstanding] : []
        // PERFORMANCE: switch off RealityKit post-processing we never use (none of it affects the captured map or mesh data).
        view.renderOptions.insert([.disableMotionBlur, .disableDepthOfField, .disableHDR, .disableCameraGrain,
                                   .disablePersonOcclusion, .disableAREnvironmentLighting, .disableGroundingShadows])
        view.scene.addAnchor(context.coordinator.root)
        return view
    }

    func updateUIView(_ view: ARView, context: Context) {
        let wanted: ARView.DebugOptions = showMesh ? [.showSceneUnderstanding] : []
        if view.debugOptions != wanted { view.debugOptions = wanted }
        context.coordinator.show(box)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// Owns the world-anchored entity that holds the wireframe so we can rebuild it on change.
    final class Coordinator {
        let root = AnchorEntity(world: .zero)
        private var lastBox: OrientedBox?

        func show(_ box: OrientedBox?) {
            guard box != lastBox else { return }
            lastBox = box
            root.children.removeAll()
            guard let box else { return }

            let corners = box.corners()
            let material = UnlitMaterial(color: .green)
            for (a, b) in OrientedBox.edgeIndices {
                let start = corners[a], end = corners[b]
                let length = simd_distance(start, end)
                guard length > 0.001 else { continue }
                let bar = ModelEntity(mesh: .generateBox(size: SIMD3<Float>(0.012, 0.012, length)), materials: [material])
                let mid = (start + end) / 2
                bar.look(at: end, from: mid, relativeTo: nil) // box length runs along local z
                root.addChild(bar)
            }
        }
    }
}
