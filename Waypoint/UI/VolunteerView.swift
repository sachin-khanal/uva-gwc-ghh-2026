//
// File:     Waypoint/UI/VolunteerView.swift
// Owner:    D (UI) with A (CaptureController / LiveScanView)
// Purpose:  Volunteer screen. Before scanning: name the building and start. While scanning (Polycam-style):
//           full-screen camera with the live LiDAR mesh and a green bounding box (`LiveScanView`), a HUD
//           (tracking, mapping quality, triangles, box size) and a bottom panel to tag Door/Stairs/Room/...,
//           grow/shrink the box, and Save once ARKit reports the area as mapped.
// Status:   SCAFFOLD, UNVERIFIED ON DEVICE. TODO(D): haptic confirmation on tag, nicer layout.
// Extension: select a downloaded/local building and saved segment, relocalize, then
//            explicitly attach near an existing corridor before tags/save unlock.
//           TODO(A+C): OCR-suggested labels; export button (USDZ) once MeshExporter exists.
//
import ARKit
import SwiftUI
import WaypointCore

struct VolunteerView: View {
    @EnvironmentObject var app: AppState
    @State private var controller: CaptureController?
    @State private var mapName = "Rice Hall, floor 1"
    @State private var recordLabels = CaptureController.launchFlag("scanClassification", default: true)
    @State private var existingMapID: UUID?
    @State private var initialSegment = ""

    private var selectedMap: BuildingMap? {
        app.maps.first { $0.id == existingMapID }
    }

    var body: some View {
        Group {
            if let controller {
                ScanningView(controller: controller, app: app) {
                    controller.stop()
                    self.controller = nil
                }
            } else {
                Form {
                    Section("Building") {
                        Picker("Scan", selection: $existingMapID) {
                            Text("Create a new building").tag(nil as UUID?)
                            ForEach(app.maps) { map in
                                Text("Extend: \(map.name)").tag(Optional(map.id))
                            }
                        }
                        .accessibilityIdentifier("scan.building")
                        .onChange(of: existingMapID) { _, _ in
                            initialSegment = selectedMap?.segmentIds.first ?? ""
                        }
                        if let selectedMap {
                            Picker("Saved scan area", selection: $initialSegment) {
                                ForEach(selectedMap.segmentIds, id: \.self) { segment in
                                    Text(segment).tag(segment)
                                }
                            }
                            Text("Start in this saved scan area. If this building came from another phone, download it and its scan files first.")
                                .font(.footnote)
                        } else {
                            TextField("Map name", text: $mapName).accessibilityIdentifier("scan.name")
                        }
                    }
                    Section {
                        Toggle("Record surface labels (walls, floor, doors)", isOn: $recordLabels)
                            .accessibilityIdentifier("scan.labels")
                    } footer: {
                        Text("Recommended for any scan you will keep: labels cannot be added to a scan afterwards. Turn off only for quick tests if scanning lags.")
                    }
                    Button("Start scanning") {
                        let c = CaptureController(store: app.store, deviceName: app.deviceName)
                        controller = c
                        c.start(mapName: mapName, recordSurfaceLabels: recordLabels,
                                extending: selectedMap, initialSegment: initialSegment)
                    }
                    .accessibilityIdentifier("scan.start")
                }
            }
        }
        .onDisappear { controller?.stop() }
        .onAppear {
            // `-autoScan YES` (see LaunchCommand): start scanning with no taps; stats are logged once per second.
            guard app.launchCommand == .scan, controller == nil else { return }
            let c = CaptureController(store: app.store, deviceName: app.deviceName)
            controller = c
            c.start(mapName: mapName)
        }
    }
}

private struct ScanningView: View {
    @ObservedObject var controller: CaptureController
    let app: AppState
    let onFinish: () -> Void
    @State private var poiLabel = ""
    @State private var viewingModel: BuildingMap?

    var body: some View {
        ZStack(alignment: .bottom) {
            LiveScanView(session: controller.session, box: controller.scanBox,
                         showMesh: controller.showMeshOverlay && !controller.isPaused, coverage: controller.showCoverage && !controller.isPaused ? controller.gaps : nil)
                .ignoresSafeArea()

            VStack(spacing: 10) {
                hud
                controls
            }
            .padding()
            .background(.regularMaterial)
        }
        .fullScreenCover(item: $viewingModel) { map in
            ModelViewerView(map: map, url: app.store.modelURL(mapId: map.id), onClose: { viewingModel = nil })
        }
    }

    // MARK: HUD

    private var hud: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(controller.trackingSummary).font(.headline).accessibilityIdentifier("hud.tracking")
            Text("Mapping: \(Self.name(controller.mappingStatus))  ·  Nodes: \(controller.nodeCount)").accessibilityIdentifier("hud.mapping")
            Text("Mesh: \(controller.triangleCount.formatted()) triangles").accessibilityIdentifier("hud.mesh")
            // Both-directions coverage. A map walked one way only relocalizes badly when the user
            // comes back the other way, so this is as important as the mesh count (D-043).
            Text("Both directions: \(Int(controller.returnCoverage * 100))%")
                .accessibilityIdentifier("hud.coverage")
                .foregroundStyle(controller.shouldWalkBack ? .orange : .primary)
            if controller.shouldWalkBack {
                Text("Walk back the way you came so the map works in both directions.")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("hud.walkBack")
            }
            if let box = controller.scanBox {
                Text(String(format: "Box: %.1f × %.1f × %.1f m", box.size.x, box.size.y, box.size.z)).accessibilityIdentifier("hud.box")
            } else {
                Text("Walk slowly and sweep the camera to start building the mesh")
                    .foregroundStyle(.secondary)
            }
            if let error = controller.errorMessage {
                Text(error).foregroundStyle(.red)
            }
            if let status = controller.extensionStatus {
                Text(status).accessibilityIdentifier("scan.extension.status")
            }
            if controller.showCoverage, let c = controller.gaps {
                Text(String(format: "Scanned: %.0f%% of the box surfaces (yellow = not scanned yet)", c.percent * 100))
                    .accessibilityIdentifier("hud.gaps")
            }
        }
        .font(.footnote.monospacedDigit())
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Controls

    private var controls: some View {
        VStack(spacing: 8) {
            if controller.needsExtensionAttachment {
                Button("I'm in the saved corridor — begin extension") { controller.beginExtension() }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("scan.extension.begin")
            }
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
                        .accessibilityIdentifier("scan.tag.\(kind.rawValue)")
                        .disabled(!controller.canRecord)
                    }
                }
            }

            Toggle("Mesh overlay (turn off if laggy; mapping continues)", isOn: $controller.showMeshOverlay)
                .font(.footnote)
                .accessibilityIdentifier("scan.overlay")
            Toggle("Show unscanned areas (yellow)", isOn: $controller.showCoverage)
                .font(.footnote)
                .accessibilityIdentifier("scan.coverage")

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
                    .disabled(controller.mappingStatus != .mapped || !controller.canRecord)
                    .accessibilityIdentifier("scan.save")
                if let saved = controller.savedMap {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Saved \(saved.nodes.count) nodes").foregroundStyle(.green)
                        if let status = controller.modelStatus {
                            Text(status).font(.footnote).accessibilityIdentifier("scan.modelStatus")
                        }
                        if app.store.hasModel(mapId: saved.id) {
                            Button("View 3D model") { viewingModel = saved }.font(.footnote).accessibilityIdentifier("scan.viewModel")
                        }
                    }
                    .onAppear { app.reloadMaps() }
                } else if controller.mappingStatus != .mapped {
                    Text("Save unlocks when mapping is complete").font(.footnote).foregroundStyle(.secondary)
                }
            }
            Button(controller.savedMap == nil ? "Cancel scan" : "Done", action: onFinish)
                .accessibilityIdentifier("scan.finish")
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
