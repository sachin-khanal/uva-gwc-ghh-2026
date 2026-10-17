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

/// The navigation ARSession's camera feed, with nothing drawn over it.
struct NavCameraView: UIViewRepresentable {
    let session: ARSession

    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero)
        // We render the session CaptureController/Relocalizer owns; we never configure or run it.
        view.automaticallyConfigureSession = false
        view.session = session
        view.renderOptions = [.disableMotionBlur, .disableDepthOfField, .disableHDR,
                              .disableGroundingShadows, .disablePersonOcclusion]
        return view
    }

    func updateUIView(_ view: ARView, context: Context) {}
}

struct NavDebugView: View {
    @ObservedObject var controller: NavigationController

    var body: some View {
        VStack(spacing: Theme.Space.s) {
            if !controller.isSimulating {
                NavCameraView(session: controller.arSession)
                    .frame(height: 180)
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
