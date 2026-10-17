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
    /// "Unscanned areas" overlay (yellow tiles + dashed white outline where the scan has no mesh yet, like Apple's Measure guides). nil = off.
    var coverage: CoverageSnapshot?

    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero)
        view.automaticallyConfigureSession = false
        view.session = session
        view.debugOptions = showMesh ? [.showSceneUnderstanding] : []
        // PERFORMANCE: switch off RealityKit post-processing we never use (none of it affects the captured map or mesh data).
        view.renderOptions.insert([.disableMotionBlur, .disableDepthOfField, .disableHDR, .disableCameraGrain,
                                   .disablePersonOcclusion, .disableAREnvironmentLighting, .disableGroundingShadows])
        view.scene.addAnchor(context.coordinator.root)
        view.scene.addAnchor(context.coordinator.coverageRoot)
        return view
    }

    func updateUIView(_ view: ARView, context: Context) {
        let wanted: ARView.DebugOptions = showMesh ? [.showSceneUnderstanding] : []
        if view.debugOptions != wanted { view.debugOptions = wanted }
        context.coordinator.show(box)
        context.coordinator.showCoverage(coverage)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// Owns the world-anchored entity that holds the wireframe so we can rebuild it on change.
    final class Coordinator {
        let root = AnchorEntity(world: .zero)
        let coverageRoot = AnchorEntity(world: .zero)
        private var lastBox: OrientedBox?
        private var lastCoverage: CoverageSnapshot?

        /// Two meshes only (fill + outline), rebuilt about once a second: thousands of separate entities would stall RealityKit.
        func showCoverage(_ snapshot: CoverageSnapshot?) {
            guard snapshot != lastCoverage else { return }
            lastCoverage = snapshot
            coverageRoot.children.removeAll()
            guard let snapshot, !snapshot.tiles.isEmpty else { return }

            // Yellow translucent tiles. Each quad is written in both windings so it is visible from either side.
            var positions: [SIMD3<Float>] = [], indices: [UInt32] = []
            for tile in snapshot.tiles where tile.corners.count == 4 {
                let base = UInt32(positions.count)
                positions += tile.corners
                indices += [base, base + 1, base + 2, base, base + 2, base + 3, base + 2, base + 1, base, base + 3, base + 2, base]
            }
            var fill = UnlitMaterial(color: UIColor.systemYellow.withAlphaComponent(0.28))
            fill.blending = .transparent(opacity: 0.28)
            if let entity = Self.entity(positions: positions, indices: indices, material: fill) { coverageRoot.addChild(entity) }

            // Dashed white outline: thin in-plane strips (one quad per dash).
            var op: [SIMD3<Float>] = [], oi: [UInt32] = []
            let half: Float = 0.008
            for seg in snapshot.outline {
                let dir = seg.b - seg.a
                let length = simd_length(dir)
                guard length > 0.001 else { continue }
                let side = simd_normalize(simd_cross(dir / length, seg.normal)) * half
                let base = UInt32(op.count)
                op += [seg.a - side, seg.b - side, seg.b + side, seg.a + side]
                oi += [base, base + 1, base + 2, base, base + 2, base + 3, base + 2, base + 1, base, base + 3, base + 2, base]
            }
            if let entity = Self.entity(positions: op, indices: oi, material: UnlitMaterial(color: .white)) { coverageRoot.addChild(entity) }
        }

        private static func entity(positions: [SIMD3<Float>], indices: [UInt32], material: any RealityKit.Material) -> ModelEntity? {
            guard !positions.isEmpty else { return nil }
            var descriptor = MeshDescriptor(name: "coverage")
            descriptor.positions = MeshBuffers.Positions(positions)
            descriptor.primitives = .triangles(indices)
            guard let mesh = try? MeshResource.generate(from: [descriptor]) else { return nil }
            return ModelEntity(mesh: mesh, materials: [material])
        }

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
