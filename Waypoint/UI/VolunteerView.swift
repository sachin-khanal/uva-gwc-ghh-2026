//
// File:     Waypoint/UI/VolunteerView.swift
// Owner:    D (UI) with A (CaptureController / LiveScanView)
// Purpose:  Volunteer screen. Before scanning: name the building and start. While scanning (Polycam-style):
//           full-screen camera with the live LiDAR mesh and a green bounding box (`LiveScanView`), a HUD
//           (tracking, mapping quality, triangles, box size) and a bottom panel to tag Door/Stairs/Room/...,
//           grow/shrink the box, and Save once ARKit reports the area as mapped.
// Status:   SCAFFOLD, UNVERIFIED ON DEVICE. TODO(D): haptic confirmation on tag, nicer layout.
//           TODO(A+C): OCR-suggested labels; export button (USDZ) once MeshExporter exists.
//
import ARKit
import SwiftUI
import WaypointCore

struct VolunteerView: View {
    @EnvironmentObject var app: AppState
    @State private var controller: CaptureController?
    @State private var mapName = "Rice Hall, floor 1"

    var body: some View {
        Group {
            if let controller {
                ScanningView(controller: controller, app: app)
            } else {
                Form {
                    Section("Building") { TextField("Map name", text: $mapName) }
                    Button("Start scanning") {
                        let c = CaptureController(store: app.store, deviceName: app.deviceName)
                        controller = c
                        c.start(mapName: mapName)
                    }
                }
            }
        }
        .onDisappear { controller?.stop() }
    }
}

private struct ScanningView: View {
    @ObservedObject var controller: CaptureController
    let app: AppState
    @State private var poiLabel = ""

    var body: some View {
        ZStack(alignment: .bottom) {
            LiveScanView(session: controller.session, box: controller.scanBox)
                .ignoresSafeArea()

            VStack(spacing: 10) {
                hud
                controls
            }
            .padding()
            .background(.regularMaterial)
        }
    }

    // MARK: HUD

    private var hud: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(controller.trackingSummary).font(.headline)
            Text("Mapping: \(Self.name(controller.mappingStatus))  ·  Nodes: \(controller.nodeCount)")
            Text("Mesh: \(controller.triangleCount.formatted()) triangles")
            if let box = controller.scanBox {
                Text(String(format: "Box: %.1f × %.1f × %.1f m", box.size.x, box.size.y, box.size.z))
            } else {
                Text("Walk slowly and sweep the camera to start building the mesh")
                    .foregroundStyle(.secondary)
            }
            if let error = controller.errorMessage {
                Text(error).foregroundStyle(.red)
            }
        }
        .font(.footnote.monospacedDigit())
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Controls

    private var controls: some View {
        VStack(spacing: 8) {
            TextField("Label for next tag (e.g. Room 204)", text: $poiLabel)
                .textFieldStyle(.roundedBorder)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach([NodeKind.room, .door, .stairs, .elevator, .junction], id: \.self) { kind in
                        Button(kind.rawValue.capitalized) {
                            controller.tagPOI(kind: kind, label: poiLabel.isEmpty ? nil : poiLabel)
                            poiLabel = ""
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }

            HStack {
                Text("Box margin \(String(format: "%.1f", controller.boxMargin)) m")
                    .font(.footnote)
                Spacer()
                Button { controller.adjustBoxMargin(by: -0.1) } label: { Image(systemName: "minus.circle") }
                    .accessibilityLabel("Shrink scan box")
                Button { controller.adjustBoxMargin(by: 0.1) } label: { Image(systemName: "plus.circle") }
                    .accessibilityLabel("Grow scan box")
            }

            HStack {
                Button("Save map") { controller.save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(controller.mappingStatus != .mapped)
                if let saved = controller.savedMap {
                    Text("Saved \(saved.nodes.count) nodes")
                        .foregroundStyle(.green)
                        .onAppear { app.reloadMaps() }
                } else if controller.mappingStatus != .mapped {
                    Text("Save unlocks when mapping is complete").font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
    }

    private static func name(_ s: ARFrame.WorldMappingStatus) -> String {
        switch s {
        case .notAvailable: return "not available"
        case .limited: return "limited"
        case .extending: return "extending"
        case .mapped: return "mapped"
        @unknown default: return "unknown"
        }
    }
}
