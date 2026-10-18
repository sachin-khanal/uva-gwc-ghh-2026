//
// File:     Cloud/SupabaseClient.swift
// Module:   WaypointCore
// Owner:    D (App/Sync/Integration)
// Purpose:  Minimal Supabase REST client (decision D-014: no Supabase SDK, plain HTTP):
//             * GoTrue   anonymous sign-in + refresh        POST /auth/v1/signup, /auth/v1/token
//             * PostgREST canonical list + atomic extension  /rest/v1/canonical_buildings, rpc/extend_building
//             * Storage  upload/download private files       /storage/v1/object/...
//           Every call carries the public `apikey` header and the user's JWT as Bearer token, so Row
//           Level Security sees `auth.uid()`.
// Setup:    In the Supabase dashboard enable Authentication > Providers > Anonymous Sign-Ins, then run
//           migrations 0001, 0002 and 0003 in the SQL editor. Status: request shapes tested against a mock; SQL
//           0001-0003 + supabase/tests PASS on a local Postgres (stubbed storage) and reported OK in
//           U3's Supabase; this client is still UNVERIFIED against a live project.
// Actor:    all mutable state (the session) is isolated; safe to call from any task.
//
import Foundation

public actor SupabaseClient {

    public let config: SupabaseConfig
    private let transport: HTTPTransport
    private let sessionStore: SessionStore
    private let now: @Sendable () -> Date
    private var session: AuthSession?

    public init(
        config: SupabaseConfig,
        transport: HTTPTransport = URLSessionTransport(),
        sessionStore: SessionStore = InMemorySessionStore(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.config = config
        self.transport = transport
        self.sessionStore = sessionStore
        self.now = now
        self.session = sessionStore.load()
    }

    // MARK: Auth

    /// Returns a valid session: reuses/refreshes the stored one, or signs in anonymously.
    public func ensureSession() async throws -> AuthSession {
        if let s = session {
            if s.expiresAt.timeIntervalSince(now()) > 60 { return s }
            if let refreshed = try? await refresh(s) { return refreshed }
        }
        return try await signInAnonymously()
    }

    public func currentUserId() async throws -> String {
        try await ensureSession().userId
    }

    public func signInAnonymously() async throws -> AuthSession {
        let req = HTTPRequest(
            url: config.url.appendingPathComponent("auth/v1/signup"),
            method: "POST",
            headers: ["apikey": config.anonKey, "Content-Type": "application/json"],
            body: Data("{}".utf8))
        return try await storeSession(from: try await sendChecked(req))
    }

    private func refresh(_ old: AuthSession) async throws -> AuthSession {
        var comps = URLComponents(url: config.url.appendingPathComponent("auth/v1/token"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "grant_type", value: "refresh_token")]
        let body = try JSONSerialization.data(withJSONObject: ["refresh_token": old.refreshToken])
        let req = HTTPRequest(
            url: comps.url!, method: "POST",
            headers: ["apikey": config.anonKey, "Content-Type": "application/json"], body: body)
        return try await storeSession(from: try await sendChecked(req))
    }

    private struct AuthResponse: Decodable {
        let access_token: String
        let refresh_token: String
        let expires_in: Double
        struct User: Decodable { let id: String }
        let user: User
    }

    private func storeSession(from data: Data) throws -> AuthSession {
        guard let r = try? JSONDecoder().decode(AuthResponse.self, from: data) else {
            throw CloudError.decoding("unexpected auth response")
        }
        let s = AuthSession(accessToken: r.access_token, refreshToken: r.refresh_token,
                            userId: r.user.id, expiresAt: now().addingTimeInterval(r.expires_in))
        session = s
        sessionStore.save(s)
        return s
    }

    // MARK: Buildings (PostgREST)

    /// Atomically add to the building's shared map (requires migration 0002).
    public func upsertBuilding(_ row: BuildingRow) async throws {
        let body = try JSONEncoder().encode(["incoming": row.map])
        _ = try await authed(
            "POST", "rest/v1/rpc/extend_building",
            headers: ["Content-Type": "application/json"],
            body: body)
    }

    /// Lists 3D surface files (OBJ) of a building that the caller has already uploaded (requires migration 0008). The server checks
    /// that every file belongs to a scan segment THIS user contributed; assets are append-only.
    public func publishMeshAssets(mapId: UUID, assets: [MeshAsset]) async throws {
        struct Args: Encodable { let building: UUID; let assets: [MeshAsset] }
        let body = try JSONEncoder().encode(Args(building: mapId, assets: assets))
        _ = try await authed(
            "POST", "rest/v1/rpc/publish_mesh_assets",
            headers: ["Content-Type": "application/json"],
            body: body)
    }

    /// One shared map per building, newest first.
    public func listBuildings() async throws -> [BuildingRow] {
        let data = try await authed(
            "GET", "rest/v1/canonical_buildings",
            query: [URLQueryItem(name: "select", value: "*"), URLQueryItem(name: "order", value: "updated_at.desc")])
        do { return try JSONDecoder().decode([BuildingRow].self, from: data) }
        catch { throw CloudError.decoding("buildings: \(error.localizedDescription)") }
    }

    // MARK: Storage

    /// Uploads (or overwrites) a private file. `path` must start with "<your user id>/" (RLS).
    public func upload(bucket: String, path: String, data: Data, contentType: String = "application/octet-stream") async throws {
        _ = try await authed(
            "POST", "storage/v1/object/\(bucket)/\(path)",
            headers: ["Content-Type": contentType, "x-upsert": "true"], body: data)
    }

    public func download(bucket: String, path: String) async throws -> Data {
        try await authed("GET", "storage/v1/object/authenticated/\(bucket)/\(path)")
    }

    // MARK: Edge Functions

    /// POSTs JSON to `functions/v1/<name>` as the signed-in (anonymous) user. Same auth, refresh and one-retry-on-401 as every other call.
    public func callFunction(_ name: String, json body: Data) async throws -> Data {
        try await authed("POST", "functions/v1/\(name)", headers: ["Content-Type": "application/json"], body: body)
    }

    // MARK: Plumbing

    private func authed(
        _ method: String, _ path: String,
        query: [URLQueryItem] = [], headers: [String: String] = [:], body: Data? = nil,
        isRetry: Bool = false
    ) async throws -> Data {
        let s = try await ensureSession()
        var comps = URLComponents(url: config.url.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { comps.queryItems = query }
        var h = headers
        h["apikey"] = config.anonKey
        h["Authorization"] = "Bearer \(s.accessToken)"
        let req = HTTPRequest(url: comps.url!, method: method, headers: h, body: body)
        do {
            return try await sendChecked(req)
        } catch CloudError.http(let status, _) where status == 401 && !isRetry {
            // Token rejected (revoked/expired early): drop it, sign in again once, retry.
            session = nil
            sessionStore.save(nil)
            return try await authed(method, path, query: query, headers: headers, body: body, isRetry: true)
        }
    }

    private func sendChecked(_ req: HTTPRequest) async throws -> Data {
        let res = try await transport.send(req)
        guard (200..<300).contains(res.status) else {
            throw CloudError.http(status: res.status, message: String(decoding: res.body.prefix(300), as: UTF8.self))
        }
        return res.body
    }
}
