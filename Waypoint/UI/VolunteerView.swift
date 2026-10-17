//
// File:     Waypoint/UI/VolunteerView.swift
// Owner:    D (UI) with A (CaptureController)
// Purpose:  Volunteer screen: name the building, start scanning, tag Door/Stairs/Elevator/Room
//           as you walk, then Save once ARKit reports the map as sufficiently mapped.
// Status:   SCAFFOLD. TODO(D): show the camera feed (optional for a sighted volunteer), haptic
//           confirmation on tag, nicer layout. TODO(A+C): offer OCR-suggested labels.
//
import ARKit
import SwiftUI
import WaypointCore

struct VolunteerView: View {
    @EnvironmentObject var app: AppState
    @State private var controller: CaptureController?
    @State private var mapName = "Rice Hall, floor 1"
    @State private var poiLabel = ""

    var body: some View {
        Group {
            if let controller {
                ScanningView(controller: controller, poiLabel: $poiLabel, app: app)
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
    @Binding var poiLabel: String
    let app: AppState

    var body: some View {
        Form {
            Section("Status") {
                Text(controller.trackingSummary)
                Text("Mapping: \(Self.name(controller.mappingStatus))")
                Text("Nodes: \(controller.nodeCount)")
            }
            Section("Tag what's in front of you") {
                TextField("Label (e.g. Room 204)", text: $poiLabel)
                ForEach([NodeKind.room, .door, .stairs, .elevator, .junction], id: \.self) { kind in
                    Button("Tag \(kind.rawValue)") {
                        controller.tagPOI(kind: kind, label: poiLabel.isEmpty ? nil : poiLabel)
                        poiLabel = ""
                    }
                }
            }
            Section {
                Button("Save map") { controller.save() }
                    .disabled(controller.mappingStatus != .mapped)
                if let saved = controller.savedMap {
                    Text("Saved \"\(saved.name)\" (\(saved.nodes.count) nodes)").foregroundStyle(.green)
                        .onAppear { app.reloadMaps() }
                }
            } footer: {
                Text("Save is enabled when ARKit reports the area as mapped. Walk slowly and look around.")
            }
            if let error = controller.errorMessage {
                Text(error).foregroundStyle(.red)
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
