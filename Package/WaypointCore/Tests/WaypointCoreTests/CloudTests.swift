//
// File:     Tests/WaypointCoreTests/CloudTests.swift
// Purpose:  Verifies the Supabase layer with a MOCK transport (no network, no project needed): request
//           shapes (URLs, headers, query, bodies), anonymous sign-in, refresh, 401 retry, error
//           mapping, and SyncEngine push/list/fetch including validation of hostile downloads.
//           If these pass but the real server rejects us, the problem is dashboard setup
//           (anonymous sign-ins on? migration applied?), not the client code.
//
import XCTest
@testable import WaypointCore

/// Records every request and answers from a handler closure.
final class MockTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [HTTPRequest] = []
    private let handler: @Sendable (HTTPRequest) -> HTTPResponse

    init(handler: @escaping @Sendable (HTTPRequest) -> HTTPResponse) { self.handler = handler }

    var requests: [HTTPRequest] { lock.lock(); defer { lock.unlock() }; return _requests }

    private func record(_ request: HTTPRequest) {
        lock.lock(); _requests.append(request); lock.unlock()
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        record(request)
        return handler(request)
    }
}

private let userId = "11111111-2222-3333-4444-555555555555"

private func authJSON(token: String = "tok1", refresh: String = "ref1", expires: Double = 3600, user: String = userId) -> Data {
    Data(#"{"access_token":"\#(token)","refresh_token":"\#(refresh)","expires_in":\#(expires),"user":{"id":"\#(user)"}}"#.utf8)
}

private func makeClient(_ transport: MockTransport, store: SessionStore = InMemorySessionStore(),
                        now: @escaping @Sendable () -> Date = { Date() }) -> SupabaseClient {
    SupabaseClient(config: SupabaseConfig(url: URL(string: "https://abc.supabase.co")!, anonKey: "ANON"),
                   transport: transport, sessionStore: store, now: now)
}

final class CloudTests: XCTestCase {

    func testSchema3UploadsMeshBeforeCanonicalManifest() async throws {
        let transport = MockTransport { request in
            request.url.path.hasPrefix("/auth/") ? HTTPResponse(status: 200, body: authJSON()) : HTTPResponse(status: 200)
        }
        let store = tempStore()
        var map = try loadSampleMap()
        let (asset, bytes) = try OBJEncoder.encode(vertices: [[0,0,0],[1,0,0],[0,1,0]],
                                                   triangles: [[0,1,2]], segmentId: "seg1")
        map.meshAssets = [asset]
        _ = try store.importBundle(MapBundle(map: map, meshFiles: [asset.id.uuidString: bytes]))
        try await SyncEngine(client: makeClient(transport), store: store).push(mapId: map.id, share: true)
        let calls = transport.requests.filter { !$0.url.path.hasPrefix("/auth/") }
        XCTAssertTrue(calls[0].url.path.hasPrefix("/storage/v1/object/meshes/"))
        XCTAssertEqual(calls[0].body, bytes)
        XCTAssertEqual(calls.last?.url.path, "/rest/v1/rpc/extend_building")
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(calls.last?.body)) as? [String: Any])
        let incoming = try XCTUnwrap(payload["incoming"] as? [String: Any])
        let assets = try XCTUnwrap(incoming["meshAssets"] as? [[String: Any]])
        XCTAssertEqual((assets[0]["storageOwner"] as? String)?.lowercased(), userId)
    }

    func testSchema3CorruptCloudMeshIsRejected() async throws {
        var map = try loadSampleMap()
        var asset = try OBJEncoder.encode(vertices: [[0,0,0],[1,0,0],[0,1,0]],
                                          triangles: [[0,1,2]], segmentId: "seg1").0
        asset.storageOwner = UUID(uuidString: userId)
        map.meshAssets = [asset]
        let row = BuildingRow(mapId: map.id, owner: UUID(uuidString: userId), name: map.name,
                              version: 1, map: map, isShared: true)
        let transport = MockTransport { request in
            if request.url.path.hasPrefix("/auth/") { return HTTPResponse(status: 200, body: authJSON()) }
            return HTTPResponse(status: 200, body: Data([0]))
        }
        do {
            _ = try await SyncEngine(client: makeClient(transport), store: tempStore())
                .fetchBundle(RemoteMap(row: row, isMine: false))
            XCTFail("Expected mesh checksum/size rejection")
        } catch is MapStoreError {}
    }

    func testConfigValidation() {
        XCTAssertNotNil(SupabaseConfig.validated(urlString: "https://abc.supabase.co", anonKey: "eyJ..."))
        XCTAssertNil(SupabaseConfig.validated(urlString: "", anonKey: "k"))
        XCTAssertNil(SupabaseConfig.validated(urlString: "https://abc.supabase.co", anonKey: nil))
        XCTAssertNil(SupabaseConfig.validated(urlString: "$(SUPABASE_URL)", anonKey: "$(SUPABASE_ANON_KEY)"))
        XCTAssertNil(SupabaseConfig.validated(urlString: "https://REPLACE.supabase.co", anonKey: "k"))
        XCTAssertNil(SupabaseConfig.validated(urlString: "http://abc.supabase.co", anonKey: "k")) // https only
    }

    func testAnonymousSignInRequestAndSessionReuse() async throws {
        let t = MockTransport { _ in HTTPResponse(status: 200, body: authJSON()) }
        let store = InMemorySessionStore()
        let client = makeClient(t, store: store)
        let s = try await client.ensureSession()
        XCTAssertEqual(s.userId, userId)
        let req = try XCTUnwrap(t.requests.first)
        XCTAssertEqual(req.url.absoluteString, "https://abc.supabase.co/auth/v1/signup")
        XCTAssertEqual(req.method, "POST")
        XCTAssertEqual(req.headers["apikey"], "ANON")
        XCTAssertEqual(store.load()?.accessToken, "tok1") // persisted
        _ = try await client.ensureSession()
        XCTAssertEqual(t.requests.count, 1, "valid session is reused, no second sign-in")
    }

    func testExpiredSessionIsRefreshed() async throws {
        let start = Date()
        let clock = LockedClock(start)
        let t = MockTransport { req in
            req.url.path.hasSuffix("token")
                ? HTTPResponse(status: 200, body: authJSON(token: "tok2", refresh: "ref2"))
                : HTTPResponse(status: 200, body: authJSON())
        }
        let client = makeClient(t, now: { clock.now })
        _ = try await client.ensureSession()
        clock.advance(7_200) // past expiry
        let s = try await client.ensureSession()
        XCTAssertEqual(s.accessToken, "tok2")
        let refreshReq = try XCTUnwrap(t.requests.last)
        XCTAssertTrue(refreshReq.url.absoluteString.contains("grant_type=refresh_token"))
        XCTAssertTrue(String(decoding: refreshReq.body ?? Data(), as: UTF8.self).contains("ref1"))
    }

    func testUpsertBuildingRequestShape() async throws {
        let t = MockTransport { req in
            req.url.path.hasPrefix("/auth/") ? HTTPResponse(status: 200, body: authJSON()) : HTTPResponse(status: 201)
        }
        let client = makeClient(t)
        let map = try loadSampleMap()
        try await client.upsertBuilding(BuildingRow(mapId: map.id, name: map.name, version: 1, map: map, isShared: true))
        let req = try XCTUnwrap(t.requests.last)
        XCTAssertEqual(req.method, "POST")
        XCTAssertEqual(req.url.path, "/rest/v1/rpc/extend_building")
        XCTAssertNil(req.url.query)
        XCTAssertEqual(req.headers["Authorization"], "Bearer tok1")
        XCTAssertEqual(req.headers["apikey"], "ANON")
        XCTAssertNil(req.headers["Prefer"])
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(req.body)) as? [String: Any])
        XCTAssertNotNil(json["incoming"] as? [String: Any])
        XCTAssertNil(json["id"], "server generates the row id")
        XCTAssertNil(json["owner"], "server fills owner from auth.uid()")
    }

    func testListBuildingsDecodes() async throws {
        let map = try loadSampleMap()
        let row = BuildingRow(rowId: UUID(), mapId: map.id, owner: UUID(uuidString: userId), name: map.name,
                              version: 1, map: map, isShared: false, updatedAt: "2026-10-17T12:00:00+00:00")
        let body = try JSONEncoder().encode([row])
        let t = MockTransport { req in
            req.url.path.hasPrefix("/auth/") ? HTTPResponse(status: 200, body: authJSON()) : HTTPResponse(status: 200, body: body)
        }
        let rows = try await makeClient(t).listBuildings()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].map, map)
        XCTAssertEqual(t.requests.last?.method, "GET")
        XCTAssertEqual(t.requests.last?.url.path, "/rest/v1/canonical_buildings")
    }

    func testHTTPErrorsAndSingle401Retry() async throws {
        let counter = Counter()
        let t = MockTransport { req in
            // Each sign-in issues a new token: tok1, tok2, ... The server only rejects tok1.
            if req.url.path.hasPrefix("/auth/") { return HTTPResponse(status: 200, body: authJSON(token: "tok\(counter.next())")) }
            return req.headers["Authorization"] == "Bearer tok1"
                ? HTTPResponse(status: 401, body: Data("jwt expired".utf8))
                : HTTPResponse(status: 200, body: Data("[]".utf8))
        }
        // First data call gets 401 -> client drops the session, signs in again once, retries, succeeds.
        let rows = try await makeClient(t).listBuildings()
        XCTAssertTrue(rows.isEmpty)
        XCTAssertEqual(t.requests.filter { $0.url.path.hasPrefix("/auth/") }.count, 2)

        let failing = MockTransport { req in
            req.url.path.hasPrefix("/auth/") ? HTTPResponse(status: 200, body: authJSON()) : HTTPResponse(status: 500, body: Data("boom".utf8))
        }
        do {
            _ = try await makeClient(failing).listBuildings()
            XCTFail("expected an error")
        } catch let CloudError.http(status, message) {
            XCTAssertEqual(status, 500)
            XCTAssertEqual(message, "boom")
        }
    }

    // MARK: SyncEngine

    private func tempStore() -> MapStore {
        MapStore(rootURL: FileManager.default.temporaryDirectory.appendingPathComponent("wp-cloud-\(UUID().uuidString)"))
    }

    func testPushUploadsWorldMapsBeforeRow() async throws {
        let t = MockTransport { req in
            req.url.path.hasPrefix("/auth/") ? HTTPResponse(status: 200, body: authJSON()) : HTTPResponse(status: 200)
        }
        let store = tempStore()
        let map = try loadSampleMap()
        try store.save(map)
        try store.saveWorldMap(Data([1, 2, 3]), mapId: map.id, segmentId: "seg1")

        try await SyncEngine(client: makeClient(t), store: store).push(mapId: map.id, share: false)

        let data = t.requests.filter { !$0.url.path.hasPrefix("/auth/") }
        XCTAssertEqual(data.count, 2)
        XCTAssertTrue(data[0].url.path.hasPrefix("/storage/v1/object/worldmaps/\(userId)/\(map.id.uuidString.lowercased())/seg1.arworldmap"))
        XCTAssertEqual(data[0].headers["x-upsert"], "true")
        XCTAssertEqual(data[0].body, Data([1, 2, 3]))
        XCTAssertEqual(data[1].url.path, "/rest/v1/rpc/extend_building", "extension is published AFTER its files")
    }

    func testPushRefusesInvalidMap() async throws {
        let t = MockTransport { _ in HTTPResponse(status: 200, body: authJSON()) }
        let store = tempStore()
        var bad = try loadSampleMap()
        bad.edges.append(MapEdge(from: bad.nodes[0].id, to: UUID(), distance: 1))
        try store.save(bad)
        do {
            try await SyncEngine(client: makeClient(t), store: store).push(mapId: bad.id, share: false)
            XCTFail("expected validation failure")
        } catch is MapStoreError {}
        XCTAssertTrue(t.requests.isEmpty, "nothing is sent for an invalid map")
    }

    func testListRemoteMarksMine() async throws {
        let map = try loadSampleMap()
        let mine = BuildingRow(rowId: UUID(), mapId: map.id, owner: UUID(uuidString: userId), name: "mine", version: 1, map: map, isShared: false)
        let theirs = BuildingRow(rowId: UUID(), mapId: map.id, owner: UUID(), name: "theirs", version: 1, map: map, isShared: true)
        let body = try JSONEncoder().encode([mine, theirs])
        let t = MockTransport { req in
            req.url.path.hasPrefix("/auth/") ? HTTPResponse(status: 200, body: authJSON()) : HTTPResponse(status: 200, body: body)
        }
        let remote = try await SyncEngine(client: makeClient(t), store: tempStore()).listRemote()
        XCTAssertEqual(remote.map(\.isMine), [true, false])
    }

    func testFetchBundleDownloadsAndValidates() async throws {
        let map = try loadSampleMap()
        let owner = UUID()
        let row = BuildingRow(rowId: UUID(), mapId: map.id, owner: owner, name: map.name, version: 1, map: map, isShared: true)
        let t = MockTransport { req in
            if req.url.path.hasPrefix("/auth/") { return HTTPResponse(status: 200, body: authJSON()) }
            return HTTPResponse(status: 200, body: Data([7, 7]))
        }
        let engine = SyncEngine(client: makeClient(t), store: tempStore())
        let bundle = try await engine.fetchBundle(RemoteMap(row: row, isMine: false))
        XCTAssertEqual(bundle.worldMaps["seg1"], Data([7, 7]))
        let dl = try XCTUnwrap(t.requests.last)
        XCTAssertTrue(dl.url.path.contains("/storage/v1/object/authenticated/worldmaps/\(owner.uuidString.lowercased())/"))

        // A hostile shared map (shortcut edge) is refused even though the download itself succeeded.
        var evil = map
        evil.edges.append(MapEdge(from: map.nodes[0].id, to: map.nodes[4].id, distance: 1))
        let evilRow = BuildingRow(rowId: UUID(), mapId: map.id, owner: owner, name: "evil", version: 1, map: evil, isShared: true)
        do {
            _ = try await engine.fetchBundle(RemoteMap(row: evilRow, isMine: false))
            XCTFail("expected rejection")
        } catch CloudError.rejected {}
    }

    func testHostileSegmentIdNeverReachesAURL() async throws {
        var map = try loadSampleMap()
        map.nodes[0].segmentId = "../../other-user/secret"
        let row = BuildingRow(rowId: UUID(), mapId: map.id, owner: UUID(), name: "evil", version: 1, map: map, isShared: true)
        let t = MockTransport { req in
            req.url.path.hasPrefix("/auth/") ? HTTPResponse(status: 200, body: authJSON()) : HTTPResponse(status: 200, body: Data([1]))
        }
        do {
            _ = try await SyncEngine(client: makeClient(t), store: tempStore()).fetchBundle(RemoteMap(row: row, isMine: false))
            XCTFail("expected rejection")
        } catch CloudError.rejected {}
        XCTAssertTrue(t.requests.filter { $0.url.path.hasPrefix("/storage/") }.isEmpty, "no storage request may be sent")

        XCTAssertThrowsError(try SyncEngine.worldMapPath(owner: UUID().uuidString, mapId: UUID(), segment: "a/../b"))
        XCTAssertThrowsError(try SyncEngine.worldMapPath(owner: "../x", mapId: UUID(), segment: "seg1"))
        XCTAssertNoThrow(try SyncEngine.worldMapPath(owner: UUID().uuidString, mapId: UUID(), segment: "seg1"))
    }

    func testKeychainSessionStoreRoundTrip() throws {
        let store = KeychainSessionStore(service: "io.github.sachin-khanal.waypoint.test.\(UUID().uuidString)", account: "t")
        let session = AuthSession(accessToken: "a", refreshToken: "r", userId: userId, expiresAt: Date(timeIntervalSince1970: 2_000_000_000))
        store.save(session)
        guard store.load() != nil else {
            throw XCTSkip("Keychain not available in this test environment (e.g. no unlocked login keychain)")
        }
        XCTAssertEqual(store.load(), session)
        store.save(nil)
        XCTAssertNil(store.load(), "saving nil clears the credential")
    }

    func testMissingWorldMapFileIsSkipped() async throws {
        let map = try loadSampleMap()
        let row = BuildingRow(rowId: UUID(), mapId: map.id, owner: UUID(), name: map.name, version: 1, map: map, isShared: true)
        let t = MockTransport { req in
            req.url.path.hasPrefix("/auth/") ? HTTPResponse(status: 200, body: authJSON()) : HTTPResponse(status: 404, body: Data("not found".utf8))
        }
        let bundle = try await SyncEngine(client: makeClient(t), store: tempStore()).fetchBundle(RemoteMap(row: row, isMine: false))
        XCTAssertTrue(bundle.worldMaps.isEmpty)
    }

    func testCanonicalScanUsesContributorStorageFolder() async throws {
        let map = try loadSampleMap()
        let contributor = UUID()
        var row = BuildingRow(mapId: map.id, owner: UUID(), name: map.name,
                              version: 1, map: map, isShared: true)
        row.segmentOwners = ["seg1": contributor.uuidString]
        let decoded = try JSONDecoder().decode(BuildingRow.self, from: JSONEncoder().encode(row))
        let t = MockTransport { req in
            req.url.path.hasPrefix("/auth/")
                ? HTTPResponse(status: 200, body: authJSON())
                : HTTPResponse(status: 200, body: Data([1]))
        }
        _ = try await SyncEngine(client: makeClient(t), store: tempStore())
            .fetchBundle(RemoteMap(row: decoded, isMine: false))
        XCTAssertTrue(t.requests.last!.url.path.contains(contributor.uuidString.lowercased()))
    }
}

// MARK: Test helpers

final class LockedClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    init(_ d: Date) { current = d }
    var now: Date { lock.lock(); defer { lock.unlock() }; return current }
    func advance(_ seconds: TimeInterval) { lock.lock(); current = current.addingTimeInterval(seconds); lock.unlock() }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    func next() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n }
}
