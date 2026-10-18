//
// File:     Cloud/SyncEngine.swift
// Module:   WaypointCore
// Owner:    D (App/Sync/Integration)
// Purpose:  Moves maps between the local `MapStore` and Supabase.
//             push(mapId:)   uploads each ARWorldMap segment to the private `worldmaps` bucket, then
//                            atomically extends the canonical building map (migration 0002).
//             listRemote()   rows visible to this user (own + shared), flagged `isMine`.
//             fetchBundle()  downloads the world maps for a row and returns a VALIDATED `MapBundle`.
//           It never writes to the local store by itself on fetch: the app decides (own maps import
//           directly; other people's maps need a user tap) - see decisions D-012 and D-015.
// Order:    world maps are uploaded BEFORE the row so a visible row never points at missing files.
// Paths:    worldmaps/<ownerId>/<mapId>/<segmentId>.arworldmap
//
import Foundation

public final class SyncEngine {

    public static let worldMapBucket = "worldmaps"
    public static let meshBucket = "meshes"

    private let client: SupabaseClient
    private let store: MapStore

    public init(client: SupabaseClient, store: MapStore) {
        self.client = client
        self.store = store
    }

    /// Builds the storage path. `segment` comes from (untrusted) map data, so it is checked here too, and
    /// `owner` must look like a UUID: no character that could change the URL's structure gets through.
    public static func worldMapPath(owner: String, mapId: UUID, segment: String) throws -> String {
        guard SegmentID.isValid(segment) else { throw CloudError.rejected("Unsafe segment id.") }
        guard UUID(uuidString: owner) != nil else { throw CloudError.rejected("Unsafe owner id.") }
        return "\(owner.lowercased())/\(mapId.uuidString.lowercased())/\(segment).arworldmap"
    }

    /// `meshes/<owner>/<mapId>/<assetId>.obj`, the path the web viewer downloads (web/cloud.js). Lowercase, UUIDs only.
    public static func meshPath(owner: String, mapId: UUID, assetId: UUID) throws -> String {
        guard UUID(uuidString: owner) != nil else { throw CloudError.rejected("Unsafe owner id.") }
        return "\(owner.lowercased())/\(mapId.uuidString.lowercased())/\(assetId.uuidString.lowercased()).obj"
    }

    /// Publishes an additive extension. All canonical maps are shared; share is retained for API compatibility.
    /// What a push actually sent, so the UI can say so instead of reporting success for a map that went up without its 3D scan.
    public struct PushReport: Equatable, Sendable {
        public var meshesPublished = 0
        /// Listed in the map but not uploaded: this phone's own file is missing or changed since it was listed (other contributors' files are not this phone's to upload and are not counted).
        public var meshesSkipped = 0
    }

    @discardableResult
    public func push(mapId: UUID, share: Bool) async throws -> PushReport {
        if store.isMeshPending(mapId: mapId) {
            throw CloudError.meshNotReady("The 3D model of this scan is still being built. Wait for \"3D model saved\", then upload again.")
        }
        // A scan file over the cloud limit never leaves the phone. Checked from file sizes BEFORE anything is loaded or sent.
        let verdict = store.shareVerdict(mapId: mapId)
        if verdict.isLocalOnly, let why = SharePolicy.message(verdict) { throw CloudError.localOnly(why) }
        let bundle = try store.makeBundle(id: mapId)
        try bundle.validate() // never upload something we would refuse to import
        let owner = try await client.currentUserId()

        for (segment, data) in bundle.worldMaps.sorted(by: { $0.key < $1.key }) {
            let path = try Self.worldMapPath(owner: owner, mapId: mapId, segment: segment)
            try await client.upload(bucket: Self.worldMapBucket, path: path, data: data)
        }
        // 3D surface files for the web viewer: only files THIS phone made (storageOwner nil or me), whose bytes still match their
        // SHA-256. They go up before the row is extended; the row itself carries no meshAssets (the server lists mine in a separate
        // call, because extending an existing building keeps its stored mesh list).
        var published: [MeshAsset] = []
        var report = PushReport()
        for var asset in bundle.map.meshAssets ?? [] where asset.storageOwner == nil || asset.storageOwner?.uuidString.lowercased() == owner.lowercased() {
            guard let data = store.loadMesh(mapId: mapId, assetId: asset.id),
                  data.count == asset.byteCount, ObjExport.sha256Hex(data) == asset.sha256 else { report.meshesSkipped += 1; continue }
            let path = try Self.meshPath(owner: owner, mapId: mapId, assetId: asset.id)
            try await client.upload(bucket: Self.meshBucket, path: path, data: data)
            asset.storageOwner = UUID(uuidString: owner)
            published.append(asset)
        }
        var outgoing = bundle.map
        outgoing.meshAssets = nil
        let row = BuildingRow(mapId: mapId, name: outgoing.name, version: outgoing.version, map: outgoing, isShared: share)
        try await client.upsertBuilding(row)
        if !published.isEmpty { try await client.publishMeshAssets(mapId: mapId, assets: published) }
        report.meshesPublished = published.count
        return report
    }

    public func listRemote() async throws -> [RemoteMap] {
        let me = try await client.currentUserId().lowercased()
        return try await client.listBuildings().map { row in
            RemoteMap(row: row, isMine: row.owner?.uuidString.lowercased() == me)
        }
    }

    /// Downloads the world maps and returns a validated bundle. World maps that are missing in
    /// storage are skipped (the map is still usable via the marker fallback), other errors propagate.
    public func fetchBundle(_ remote: RemoteMap) async throws -> MapBundle {
        try await fetchBundleChecked(remote).bundle
    }

    /// A downloaded map and the scan segments whose files could NOT be downloaded (missing in storage, or hidden by a storage access rule).
    /// A map without its scan file imports fine but can never relocalize, so callers must tell the user (live test 2026-10-17: a second
    /// user got the map but 0 bytes of every scan because the storage read rule was not active).
    public struct FetchedBundle: Sendable {
        public var bundle: MapBundle
        public var missingSegments: [String]
    }

    public func fetchBundleChecked(_ remote: RemoteMap) async throws -> FetchedBundle {
        guard let owner = remote.row.owner?.uuidString else {
            throw CloudError.rejected("Remote map has no owner.")
        }
        // Validate the map FIRST (including segment ids) so a hostile map cannot steer any download URL.
        do { try MapBundle(map: remote.row.map).validate() }
        catch MapStoreError.rejected(let reason) { throw CloudError.rejected(reason) }

        var worldMaps: [String: Data] = [:]
        var missing: [String] = []
        for segment in remote.row.map.segmentIds {
            let segmentOwner = remote.row.segmentOwners?[segment] ?? owner
            let path = try Self.worldMapPath(owner: segmentOwner, mapId: remote.row.mapId, segment: segment)
            do {
                worldMaps[segment] = try await client.download(bucket: Self.worldMapBucket, path: path)
            } catch CloudError.http(let status, _) where status == 400 || status == 404 {
                missing.append(segment)
                continue
            }
        }
        let bundle = MapBundle(map: remote.row.map, worldMaps: worldMaps)
        do { try bundle.validate() } catch MapStoreError.rejected(let reason) { throw CloudError.rejected(reason) }
        return FetchedBundle(bundle: bundle, missingSegments: missing)
    }
}
