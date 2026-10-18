//
// File:     Tests/WaypointCoreTests/SharePolicyTests.swift
// Purpose:  A scan file over the 50 MB sharing limit: saves locally, never uploads, never sends, and is explained to the person.
//
import XCTest
@testable import WaypointCore

final class SharePolicyTests: XCTestCase {

    private func tempStore() -> MapStore {
        MapStore(rootURL: FileManager.default.temporaryDirectory.appendingPathComponent("share-\(UUID().uuidString)", isDirectory: true))
    }
    private func smallMap() -> BuildingMap {
        let a = MapNode(kind: .corridor, position: [0, 0, 0], segmentId: "seg1")
        let b = MapNode(kind: .room, label: "Room 1", position: [3, 0, 0], segmentId: "seg1")
        return BuildingMap(name: "Long hallway", nodes: [a, b], edges: [MapEdge(from: a.id, to: b.id, distance: 3)])
    }

    func testVerdictThresholds() {
        XCTAssertEqual(SharePolicy.evaluate(worldMapBytes: [:]), .ok)
        XCTAssertEqual(SharePolicy.evaluate(worldMapBytes: ["seg1": 27_500_000]), .ok)
        XCTAssertEqual(SharePolicy.evaluate(worldMapBytes: ["seg1": 40_000_000]), .ok, "40 MB exactly is still fine")
        XCTAssertEqual(SharePolicy.evaluate(worldMapBytes: ["seg1": 45_000_000]), .nearLimit(bytes: 45_000_000))
        XCTAssertEqual(SharePolicy.evaluate(worldMapBytes: ["seg1": 50_000_000]), .nearLimit(bytes: 50_000_000), "exactly the limit is still allowed")
        XCTAssertEqual(SharePolicy.evaluate(worldMapBytes: ["seg1": 50_000_001]), .localOnly(segment: "seg1", bytes: 50_000_001))
        // the largest file decides, even when other segments are small
        XCTAssertEqual(SharePolicy.evaluate(worldMapBytes: ["a": 1_000, "b": 61_000_000, "c": 2_000]), .localOnly(segment: "b", bytes: 61_000_000))
        XCTAssertTrue(SharePolicy.evaluate(worldMapBytes: ["seg1": 51_000_000]).isLocalOnly)
        XCTAssertFalse(SharePolicy.evaluate(worldMapBytes: ["seg1": 49_000_000]).isLocalOnly)
    }

    func testMessagesSayWhatHappens() {
        XCTAssertNil(SharePolicy.message(.ok))
        let near = SharePolicy.message(.nearLimit(bytes: 45_000_000)) ?? ""
        XCTAssertTrue(near.contains("45.0 MB") && near.contains("50.0 MB"), near)
        let over = SharePolicy.message(.localOnly(segment: "s", bytes: 61_234_567)) ?? ""
        XCTAssertTrue(over.contains("61.2 MB") && over.contains("stays on this phone"), over)
        XCTAssertEqual(SharePolicy.megabytes(27_500_000), "27.5 MB")
    }

    func testALongScanOverTheLimitCanStillBeSavedLocally() throws {
        let store = tempStore()
        let map = smallMap()
        let big = Data(count: 51_000_000)
        let stored = try store.saveLocalScan(map: map, worldMap: big, segmentId: "seg1")
        XCTAssertEqual(stored.id, map.id)
        XCTAssertEqual(try store.load(id: map.id).nodes.count, 2)
        XCTAssertEqual(try store.loadWorldMap(mapId: map.id, segmentId: "seg1")?.count, 51_000_000)
        XCTAssertEqual(store.worldMapByteCounts(mapId: map.id), ["seg1": 51_000_000])
        XCTAssertTrue(store.shareVerdict(mapId: map.id).isLocalOnly)
    }

    func testTheSharingGateStillRefusesAnOversizeBundleFromOutside() throws {
        // Incoming bundles keep the 50 MB limit (denial-of-service protection); only the phone's OWN scan may be larger.
        let store = tempStore()
        let bundle = MapBundle(map: smallMap(), worldMaps: ["seg1": Data(count: MapBundle.maxWorldMapBytes + 1)])
        XCTAssertThrowsError(try store.importBundle(bundle))
        XCTAssertTrue(store.worldMapByteCounts(mapId: bundle.map.id).isEmpty, "nothing was stored")
    }

    func testLocalSaveStillValidatesTheMapAndTheSegmentId() throws {
        let store = tempStore()
        XCTAssertThrowsError(try store.saveLocalScan(map: smallMap(), worldMap: Data(count: 10), segmentId: "../evil"))
        var broken = smallMap()
        broken.edges[0].distance = 99 // does not match the node positions
        XCTAssertThrowsError(try store.saveLocalScan(map: broken, worldMap: Data(count: 10), segmentId: "seg1"))
        XCTAssertTrue(try store.listMaps().isEmpty)
    }

    func testExtendingAnOverSizeMapKeepsBothScans() throws {
        let store = tempStore()
        var map = smallMap()
        try store.saveLocalScan(map: map, worldMap: Data(count: 51_000_000), segmentId: "seg1")
        let tail = MapNode(kind: .room, label: "Room 2", position: [6, 0, 0], segmentId: "seg2")
        map.nodes.append(tail)
        map.edges.append(MapEdge(from: map.nodes[1].id, to: tail.id, distance: 3))
        try store.saveLocalScan(map: map, worldMap: Data(count: 1_000), segmentId: "seg2")
        XCTAssertEqual(store.worldMapByteCounts(mapId: map.id), ["seg1": 51_000_000, "seg2": 1_000])
        XCTAssertEqual(try store.load(id: map.id).nodes.count, 3)
        XCTAssertTrue(store.shareVerdict(mapId: map.id).isLocalOnly, "one big segment keeps the whole map local")
    }

    func testCloudUploadOfAnOverSizeMapMakesNoNetworkCallAndExplainsWhy() async throws {
        let store = tempStore()
        let map = smallMap()
        try store.saveLocalScan(map: map, worldMap: Data(count: 51_000_000), segmentId: "seg1")
        let transport = MockTransport { _ in HTTPResponse(status: 500, body: Data()) }
        let client = SupabaseClient(config: SupabaseConfig(url: URL(string: "https://abc.supabase.co")!, anonKey: "ANON"),
                                    transport: transport, sessionStore: InMemorySessionStore(), now: { Date() })
        do {
            try await SyncEngine(client: client, store: store).push(mapId: map.id, share: true)
            XCTFail("an over-size map must not upload")
        } catch CloudError.localOnly(let why) {
            XCTAssertTrue(why.contains("stays on this phone"), why)
        }
        XCTAssertTrue(transport.requests.isEmpty, "not even a sign-in request: the check runs before any network use")
    }

    func testAMapUnderTheLimitStillPassesThePreflight() throws {
        let store = tempStore()
        let map = smallMap()
        try store.saveLocalScan(map: map, worldMap: Data(count: 27_500_000), segmentId: "seg1")
        XCTAssertEqual(store.shareVerdict(mapId: map.id), .ok)
        XCTAssertFalse(store.shareVerdict(mapId: map.id).isLocalOnly)
    }
}
