//
// File:     Waypoint/Scan/MeshExporter.swift
// Owner:    C (export) with A (scan)
// Purpose:  Turns the LiDAR mesh of a finished scan into a 3D MODEL FILE (USDZ) stored next to the map (`MapStore.modelURL`), so the map can
//           be viewed in 3D (`ModelViewerView`) and later shared. Pipeline, all pure except the two Apple calls:
//             ARMeshAnchor snapshots -> world-space `IndexedMesh` (here) -> crop to the scan box -> vertex-cluster to the size budget
//             (WaypointCore: MeshCrop, MeshDecimator) -> ModelIO MDLMesh with normals + a grey material -> SCNScene -> `.usdz` (here).
//           (ModelIO alone cannot write .usdz on iOS; SceneKit can.)
// Frames:   vertices are written in the MAP/world frame of the scan session, the same frame as the map's nodes, so pins line up.
// Threading: call from a BACKGROUND queue. It reads immutable anchor snapshots and takes seconds for big scans.
// Status:   SCAFFOLD. The pure parts are unit-tested; USDZ writing is checked on a phone by the E2E self-test (`export.usdz`).
//           UNVERIFIED ON DEVICE with a real scan mesh. TODO(C): colour by ARMeshClassification, share the file with the map bundle.
//
import ARKit
import ModelIO
import SceneKit
import SceneKit.ModelIO
import WaypointCore

enum MeshExporter {

    struct Report: Equatable {
        var fileBytes: Int
        var vertices: Int
        var triangles: Int
        /// nil = the mesh already fit the budget and was not simplified.
        var clusterCellSize: Float?
        var fitsBudget: Bool
    }

    struct ExportError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// World-space triangles of all anchors, concatenated.
    /// - Parameter worldToMap: carries the vertices into the MAP frame. Identity when the session frame
    ///   already IS the map frame (ARKit relocalized, or a fresh scan); a hand-aligned extension needs
    ///   the real transform, because `MeshAsset.coordinateFrame` claims "map" and the pins drawn on the
    ///   model come from map-frame nodes (device report 2026-10-18).
    static func extract(anchors: [ARMeshAnchor], worldToMap: simd_float4x4 = matrix_identity_float4x4) -> IndexedMesh {
        var mesh = IndexedMesh()
        for anchor in anchors {
            let geometry = anchor.geometry
            let vertices = geometry.vertices, faces = geometry.faces
            guard vertices.count > 0, faces.count > 0, faces.indexCountPerPrimitive == 3, faces.bytesPerIndex == 4 else { continue }
            let base = UInt32(mesh.vertices.count)
            let m = worldToMap * anchor.transform
            let vbase = vertices.buffer.contents().advanced(by: vertices.offset)
            for i in 0..<vertices.count {
                let f = vbase.advanced(by: i * vertices.stride).assumingMemoryBound(to: Float.self)
                let x = f[0], y = f[1], z = f[2]
                mesh.vertices.append(SIMD3<Float>(m.columns.0.x * x + m.columns.1.x * y + m.columns.2.x * z + m.columns.3.x,
                                                  m.columns.0.y * x + m.columns.1.y * y + m.columns.2.y * z + m.columns.3.y,
                                                  m.columns.0.z * x + m.columns.1.z * y + m.columns.2.z * z + m.columns.3.z))
            }
            let ibase = faces.buffer.contents().assumingMemoryBound(to: UInt32.self)
            for k in 0..<(faces.count * 3) { mesh.indices.append(base + ibase[k]) }
        }
        return mesh
    }

    /// Full export. `box` crops stray geometry; nil keeps everything.
    static func export(anchors: [ARMeshAnchor], box: OrientedBox?, to url: URL,
                       worldToMap: simd_float4x4 = matrix_identity_float4x4,
                       budgetBytes: Int = ExportBudget.defaultBudgetBytes) throws -> Report {
        var mesh = extract(anchors: anchors, worldToMap: worldToMap)
        if let box { mesh = MeshCrop.crop(mesh, to: box) }
        guard !mesh.isEmpty else { throw ExportError(message: "There was no mesh to export.") }
        let fitted = MeshDecimator.fit(mesh, budgetBytes: budgetBytes)
        try writeUSDZ(fitted.mesh, to: url)
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        return Report(fileBytes: size, vertices: fitted.mesh.vertices.count, triangles: fitted.mesh.triangleCount,
                      clusterCellSize: fitted.cellSize, fitsBudget: fitted.fitsBudget && size <= budgetBytes)
    }

    /// Writes `mesh` as USDZ (atomically: a temp file is moved into place only when complete).
    static func writeUSDZ(_ mesh: IndexedMesh, to url: URL) throws {
        guard !mesh.isEmpty else { throw ExportError(message: "The mesh is empty.") }

        let allocator = MDLMeshBufferDataAllocator()
        var floats: [Float] = []
        floats.reserveCapacity(mesh.vertices.count * 3)
        for v in mesh.vertices { floats += [v.x, v.y, v.z] }
        let vertexBuffer = allocator.newBuffer(with: floats.withUnsafeBufferPointer { Data(buffer: $0) }, type: .vertex)
        let indexBuffer = allocator.newBuffer(with: mesh.indices.withUnsafeBufferPointer { Data(buffer: $0) }, type: .index)

        let material = MDLMaterial(name: "scan", scatteringFunction: MDLPhysicallyPlausibleScatteringFunction())
        material.setProperty(MDLMaterialProperty(name: "baseColor", semantic: .baseColor, float3: SIMD3<Float>(0.78, 0.80, 0.84)))
        let submesh = MDLSubmesh(indexBuffer: indexBuffer, indexCount: mesh.indices.count, indexType: .uInt32,
                                 geometryType: .triangles, material: material)

        let descriptor = MDLVertexDescriptor()
        descriptor.attributes[0] = MDLVertexAttribute(name: MDLVertexAttributePosition, format: .float3, offset: 0, bufferIndex: 0)
        descriptor.layouts[0] = MDLVertexBufferLayout(stride: 12)
        let mdlMesh = MDLMesh(vertexBuffer: vertexBuffer, vertexCount: mesh.vertices.count, descriptor: descriptor, submeshes: [submesh])
        mdlMesh.addNormals(withAttributeNamed: MDLVertexAttributeNormal, creaseThreshold: 0.35) // lit shading in the viewer needs normals

        let asset = MDLAsset()
        asset.add(mdlMesh)
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("export-\(UUID().uuidString).usdz")
        defer { try? FileManager.default.removeItem(at: temp) }
        // ModelIO cannot write .usdz on iOS (`MDLAsset.canExportFileExtension("usdz")` is false, found on the phone 2026-10-17); SceneKit can.
        guard SCNScene(mdlAsset: asset).write(to: temp, options: nil, delegate: nil, progressHandler: nil) else {
            throw ExportError(message: "Could not write the USDZ file.")
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        try FileManager.default.moveItem(at: temp, to: url)
    }
}

// OBJ path used by the web viewer; independent of the existing USDZ pipeline.
extension MeshExporter {
    struct Snapshot {
        var vertices: [SIMD3<Float>] = []
        var triangles: [SIMD3<Int>] = []
    }

    static func snapshot(_ anchors: [ARMeshAnchor]) throws -> Snapshot {
        var result = Snapshot()
        for anchor in anchors {
            let g = anchor.geometry, offset = result.vertices.count
            guard g.faces.indexCountPerPrimitive == 3,
                  g.faces.bytesPerIndex == 4 || g.faces.bytesPerIndex == 2 else {
                throw MapStoreError.rejected("Unsupported mesh index layout.")
            }
            guard offset + g.vertices.count <= 500_000,
                  result.triangles.count + g.faces.count <= 1_000_000 else {
                throw MapStoreError.rejected("Scan is too large to export. Save a shorter scan.")
            }
            for i in 0..<g.vertices.count {
                let p = g.vertices.buffer.contents().advanced(by: g.vertices.offset + i * g.vertices.stride)
                    .assumingMemoryBound(to: Float.self)
                let world = anchor.transform * SIMD4<Float>(p[0], p[1], p[2], 1)
                result.vertices.append(SIMD3(world.x, world.y, world.z))
            }
            for face in 0..<g.faces.count {
                var indices = SIMD3<Int>()
                for corner in 0..<3 {
                    let p = g.faces.buffer.contents().advanced(by: (face * 3 + corner) * g.faces.bytesPerIndex)
                    let index = g.faces.bytesPerIndex == 4 ? Int(p.load(as: UInt32.self)) : Int(p.load(as: UInt16.self))
                    guard index < g.vertices.count else { throw MapStoreError.rejected("Invalid mesh index.") }
                    indices[corner] = offset + index
                }
                result.triangles.append(indices)
            }
        }
        return result
    }

    /// Median height of classified floor vertices near the volunteer; no guessed eye height.
    static func floorHeight(_ anchors: [ARMeshAnchor], near seed: SIMD3<Float>) -> Float? {
        var heights: [Float] = []
        for anchor in anchors {
            let g = anchor.geometry
            guard let c = g.classification, g.faces.bytesPerIndex == 4,
                  g.faces.indexCountPerPrimitive == 3 else { continue }
            for face in stride(from: 0, to: g.faces.count, by: 3) {
                let raw = c.buffer.contents().advanced(by: c.offset + face * c.stride).load(as: UInt8.self)
                guard ARMeshClassification(rawValue: Int(raw)) == .floor else { continue }
                let index = Int(g.faces.buffer.contents().advanced(by: face * 3 * 4).load(as: UInt32.self))
                guard index < g.vertices.count else { continue }
                let p = g.vertices.buffer.contents().advanced(by: g.vertices.offset + index * g.vertices.stride)
                    .assumingMemoryBound(to: Float.self)
                let w = anchor.transform * SIMD4<Float>(p[0], p[1], p[2], 1)
                if abs(w.x - seed.x) <= 3, abs(w.z - seed.z) <= 3, w.y < seed.y,
                   seed.y - w.y < 3, w.y.isFinite { heights.append(w.y) }
            }
        }
        guard !heights.isEmpty else { return nil }
        heights.sort()
        return heights[heights.count / 2]
    }
}
