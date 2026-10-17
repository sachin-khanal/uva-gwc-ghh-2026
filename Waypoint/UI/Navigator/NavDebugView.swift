//
// File:     Waypoint/UI/Navigator/NavDebugView.swift
// Owner:    U3 (UI flows) / B (navigation)
// Purpose:  The sighted DEBUG view for the blind-user tryout: the camera the app is actually tracking
//           with, and the route it has actually computed, side by side. Asked for after a Rice Hall
//           walk where the cues felt wrong and there was no way to see WHY (2026-10-17).
//           Shows: live camera, floor plan with the computed route and the user's position/heading,
//           plus the raw status, instruction and route length.
// Not for the blind user: this is a debugging aid for whoever is escorting. It is behind a setting
//           (Settings > Show debug overlay) and off by default.
// Status:   SCAFFOLD, UNVERIFIED ON DEVICE.
//
import ARKit
import RealityKit
import SwiftUI
import WaypointCore

/// The navigation ARSession's camera feed with the COMPUTED ROUTE drawn over the real world: a marker
/// standing at each waypoint and a ribbon along the floor between them. Asked for after a Rice Hall
/// walk - seeing the path only on a separate plan widget made it hard to tell whether the route or the
/// positioning was at fault (2026-10-17).
///
/// The waypoints arrive already in ARKit world coordinates (`NavigationController.routeWorldPositions`),
/// which only change when the route or the map->world transform changes, so the scene is rebuilt rarely
/// rather than every frame.
struct NavCameraView: UIViewRepresentable {
    let session: ARSession
    var routeWorldPositions: [SIMD3<Float>] = []

    final class Coordinator {
        let anchor = AnchorEntity(world: .zero)
        var drawnCount = -1
        var drawnFirst: SIMD3<Float>?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero)
        // We render the session CaptureController/Relocalizer owns; we never configure or run it.
        view.automaticallyConfigureSession = false
        view.session = session
        view.renderOptions = [.disableMotionBlur, .disableDepthOfField, .disableHDR,
                              .disableGroundingShadows, .disablePersonOcclusion]
        view.scene.addAnchor(context.coordinator.anchor)
        return view
    }

    func updateUIView(_ view: ARView, context: Context) {
        let coordinator = context.coordinator
        // Rebuild only when the route actually changed.
        guard coordinator.drawnCount != routeWorldPositions.count
                || coordinator.drawnFirst != routeWorldPositions.first else { return }
        coordinator.drawnCount = routeWorldPositions.count
        coordinator.drawnFirst = routeWorldPositions.first
        coordinator.anchor.children.removeAll()

        let marker = SimpleMaterial(color: .systemYellow, roughness: 0.4, isMetallic: false)
        let ribbon = SimpleMaterial(color: UIColor.systemYellow.withAlphaComponent(0.6),
                                    roughness: 0.6, isMetallic: false)

        for (index, point) in routeWorldPositions.enumerated() {
            // Waypoints sit on the FLOOR, a little below the phone, so they read as "on the ground".
            let base = SIMD3<Float>(point.x, point.y - 1.2, point.z)
            let sphere = ModelEntity(mesh: .generateSphere(radius: index == routeWorldPositions.count - 1 ? 0.18 : 0.1),
                                     materials: [marker])
            sphere.position = base
            coordinator.anchor.addChild(sphere)

            guard index + 1 < routeWorldPositions.count else { continue }
            let next = routeWorldPositions[index + 1]
            let nextBase = SIMD3<Float>(next.x, next.y - 1.2, next.z)
            let delta = nextBase - base
            let length = simd_length(delta)
            guard length > 0.05 else { continue }
            let segment = ModelEntity(mesh: .generateBox(size: SIMD3(0.12, 0.02, length)), materials: [ribbon])
            segment.position = base + delta / 2
            // Point the box's local z along the segment; the floor plane is all that matters.
            segment.orientation = simd_quatf(from: SIMD3(0, 0, 1), to: simd_normalize(delta))
            coordinator.anchor.addChild(segment)
        }
    }
}

struct NavDebugView: View {
    @ObservedObject var controller: NavigationController

    var body: some View {
        VStack(spacing: Theme.Space.s) {
            if !controller.isSimulating {
                NavCameraView(session: controller.arSession,
                              routeWorldPositions: controller.routeWorldPositions)
                    .frame(height: 260)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                    .accessibilityHidden(true) // a camera picture tells a VoiceOver user nothing
            }

            if let map = controller.activeMap {
                PlanView(map: map,
                         route: controller.routeNodeIds,
                         userPosition: controller.mapPosition,
                         userHeading: controller.headingRadians,
                         dark: true)
                    .frame(height: 220)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(controller.statusText).font(.caption).bold()
                if !controller.instructionText.isEmpty {
                    Text(controller.instructionText).font(.caption2).monospaced()
                }
                Text(routeDescription).font(.caption2).foregroundStyle(.secondary)
                if !controller.lastSpoken.isEmpty {
                    Text("said: \(controller.lastSpoken)").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
        }
        .padding(Theme.Space.s)
        .background(Theme.Nav.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }

    private var routeDescription: String {
        let count = controller.routeNodeIds.count
        guard count > 0 else { return "no route yet" }
        guard let map = controller.activeMap else { return "\(count) waypoints" }
        let nodes = controller.routeNodeIds.compactMap { id in map.nodes.first { $0.id == id } }
        var metres: Float = 0
        for i in 0..<max(0, nodes.count - 1) {
            metres += Geometry.horizontalDistance(nodes[i].position, nodes[i + 1].position)
        }
        return String(format: "route: %d waypoints, %.1f m", count, metres)
    }
}
