// File: Model/MeshAsset.swift
// Owner: D / U3 (schema 3 shared contract)
// Purpose: Manifest for untextured triangular OBJ geometry, stored separately from map JSON.
// Frames: Vertex coordinates and bounds are MAP-frame meters; transforms are baked at export.
// Status: Implemented; Mac tests and physical LiDAR export UNVERIFIED ON DEVICE.
import Foundation
import CryptoKit

public struct MeshAsset: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var segmentId: String
    public var format: String
    public var coordinateFrame: String
    public var byteCount: Int
    public var sha256: String
    public var boundsMin: SIMD3<Float>
    public var boundsMax: SIMD3<Float>
    /// Assigned on cloud publication. Paths are derived from UUIDs, never arbitrary URLs.
    public var storageOwner: UUID?

    public init(id: UUID = UUID(), segmentId: String, byteCount: Int, sha256: String,
                boundsMin: SIMD3<Float>, boundsMax: SIMD3<Float>, storageOwner: UUID? = nil) {
        self.id = id; self.segmentId = segmentId; self.format = "obj"; self.coordinateFrame = "map"
        self.byteCount = byteCount; self.sha256 = sha256
        self.boundsMin = boundsMin; self.boundsMax = boundsMax; self.storageOwner = storageOwner
    }

    public static let maxBytes = 40_000_000
    public static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    public func validate() throws {
        guard SegmentID.isValid(segmentId), format == "obj", coordinateFrame == "map",
              (1...Self.maxBytes).contains(byteCount), sha256.utf8.count == 64,
              sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              (0..<3).allSatisfy({ boundsMin[$0].isFinite && boundsMax[$0].isFinite && boundsMin[$0] <= boundsMax[$0] }) else {
            throw MapStoreError.rejected("Invalid mesh asset metadata.")
        }
    }
    public func validate(data: Data) throws {
        try validate()
        guard data.count == byteCount, Self.digest(data) == sha256 else {
            throw MapStoreError.rejected("Mesh file size or checksum does not match its manifest.")
        }
    }
}
