//
// File:     Waypoint/Model3D/ModelViewerView.swift
// Owner:    C (export / 3D viewer)
// Purpose:  Shows a saved scan as a 3D model you can orbit (one finger), pan (two fingers) and zoom (pinch), with the map's labelled places
//           pinned on it (rooms, doors, stairs...) and a toggle for the pins. Loads the USDZ that `MeshExporter` wrote next to the map.
// Frames:   the model and the map nodes share the scan session's world frame (+y up), so a node's position is the pin position.
// Accessibility: the 3D view itself is decorative for VoiceOver (a blind user gets the same information from the navigator); the header
//           and the place list are real text.
// Status:   SCAFFOLD, UNVERIFIED ON DEVICE with a real scan model.
//
import SceneKit
import SwiftUI
import WaypointCore

struct ModelViewerView: View {
    let map: BuildingMap
    /// One file per scan SEGMENT: an extension adds to the building rather than replacing it.
    let urls: [URL]
    let onClose: () -> Void

    @State private var showPins = true
    @State private var loadError: String?
    @State private var triangleCount: Int?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("3D model").font(.headline).accessibilityAddTraits(.isHeader)
                    Text(subtitle).font(.footnote).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done", action: onClose).font(.headline)
            }
            .padding()

            if let loadError {
                Text(loadError).foregroundStyle(.red).padding()
                Spacer()
            } else {
                SceneKitModelView(urls: urls, map: map, showPins: showPins, onLoaded: { triangleCount = $0 }, onError: { loadError = $0 })
                    .accessibilityHidden(true)
                    .accessibilityIdentifier("model.view")
                Toggle("Show places", isOn: $showPins)
                    .padding()
                    .accessibilityIdentifier("model.pins")
                Text("One finger orbits, two fingers move, pinch zooms.")
                    .font(.footnote).foregroundStyle(.secondary).padding(.bottom, 8)
            }
        }
        .background(Color(uiColor: .systemBackground))
    }

    private var subtitle: String {
        var parts = [map.name]
        if let n = triangleCount { parts.append("\(n.formatted()) triangles") }
        // Every part of the building together, not just the first file.
        let bytes = urls.reduce(0) { total, u in
            total + (((try? FileManager.default.attributesOfItem(atPath: u.path)[.size]) as? Int) ?? 0)
        }
        if bytes > 0 {
            parts.append(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))
        }
        return parts.joined(separator: " · ")
    }
}

private struct SceneKitModelView: UIViewRepresentable {
    let urls: [URL]
    let map: BuildingMap
    let showPins: Bool
    let onLoaded: (Int) -> Void
    let onError: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator { var pins: SCNNode? }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = UIColor.secondarySystemBackground
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = true
        view.antialiasingMode = .multisampling4X

        // Every segment's model in one scene. A building scanned in several passes has one file per
        // pass, and they share the MAP frame, so simply adding them lines them up (2026-10-18).
        let scene = SCNScene()
        var loaded = 0
        for modelURL in urls {
            do {
                let part = try SCNScene(url: modelURL, options: nil)
                for child in part.rootNode.childNodes { scene.rootNode.addChildNode(child) }
                loaded += 1
            } catch {
                Log.app.error("3D model part failed to open: \(modelURL.lastPathComponent) \(error.localizedDescription)")
            }
        }
        guard loaded > 0 else {
            DispatchQueue.main.async { onError("Could not open the 3D model.") }
            return view
        }
        view.scene = scene

        // Count triangles and frame the model.
        var triangles = 0
        scene.rootNode.enumerateHierarchy { node, _ in
            for element in node.geometry?.elements ?? [] { triangles += element.primitiveCount }
        }
        DispatchQueue.main.async { onLoaded(triangles) }

        let (minB, maxB) = scene.rootNode.boundingBox
        let centre = SCNVector3((minB.x + maxB.x) / 2, (minB.y + maxB.y) / 2, (minB.z + maxB.z) / 2)
        let extent = max(maxB.x - minB.x, maxB.y - minB.y, maxB.z - minB.z, 1)
        let camera = SCNNode()
        camera.camera = SCNCamera()
        camera.camera?.zFar = Double(extent) * 10
        camera.position = SCNVector3(centre.x, centre.y + extent * 0.9, centre.z + extent * 1.1)
        camera.look(at: centre)
        scene.rootNode.addChildNode(camera)
        view.pointOfView = camera

        let pins = Self.pinsNode(for: map)
        scene.rootNode.addChildNode(pins)
        context.coordinator.pins = pins
        pins.isHidden = !showPins
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        context.coordinator.pins?.isHidden = !showPins
    }

    /// One sphere + billboard label per labelled place. Sized for a building: spheres 12 cm, text about 25 cm tall.
    private static func pinsNode(for map: BuildingMap) -> SCNNode {
        let root = SCNNode()
        for node in map.nodes where (node.label?.isEmpty == false) || node.kind != .corridor {
            let color: UIColor = {
                switch node.kind {
                case .room: return .systemBlue
                case .door: return .systemOrange
                case .stairs, .elevator: return .systemRed
                case .junction: return .systemGreen
                case .corridor: return .systemGray
                }
            }()
            let sphere = SCNSphere(radius: 0.12)
            sphere.firstMaterial?.diffuse.contents = color
            let pin = SCNNode(geometry: sphere)
            pin.position = SCNVector3(node.position.x, node.position.y + 1.0, node.position.z)
            if let label = node.label, !label.isEmpty {
                let text = SCNText(string: label, extrusionDepth: 0.01)
                text.font = UIFont.systemFont(ofSize: 0.22, weight: .semibold)
                text.firstMaterial?.diffuse.contents = UIColor.label
                let textNode = SCNNode(geometry: text)
                let (lo, hi) = text.boundingBox
                textNode.pivot = SCNMatrix4MakeTranslation((lo.x + hi.x) / 2, 0, 0)
                textNode.position = SCNVector3(0, 0.2, 0)
                let billboard = SCNBillboardConstraint()
                billboard.freeAxes = .Y
                textNode.constraints = [billboard]
                pin.addChildNode(textNode)
            }
            root.addChildNode(pin)
        }
        return root
    }
}
