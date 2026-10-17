//
// File:     Cloud/CloudModels.swift
// Module:   WaypointCore
// Owner:    D (App/Sync/Integration)
// Purpose:  Config, session and row types for the Supabase backend. These mirror
//           supabase/migrations/0001_init.sql - if you change one, change the other and note it in
//           docs/WORKLOG.md.
//
import Foundation

/// Project URL + PUBLIC anon key. The anon key ships inside the app, so it is not a secret and ALL
/// authorization is enforced by Row Level Security in the database. NEVER put the service-role key
/// anywhere in this repo or app.
public struct SupabaseConfig: Equatable, Sendable {
    public var url: URL
    public var anonKey: String

    public init(url: URL, anonKey: String) {
        self.url = url
        self.anonKey = anonKey
    }

    /// Builds a config from raw strings (e.g. Info.plist values). Returns nil for empty strings,
    /// unexpanded `$(VAR)` placeholders, "REPLACE..." template values, or a non-https URL.
    public static func validated(urlString: String?, anonKey: String?) -> SupabaseConfig? {
        guard let urlString = urlString?.trimmingCharacters(in: .whitespaces),
              let anonKey = anonKey?.trimmingCharacters(in: .whitespaces),
              !urlString.isEmpty, !anonKey.isEmpty,
              !urlString.contains("$("), !anonKey.contains("$("),
              !urlString.uppercased().contains("REPLACE"), !anonKey.uppercased().contains("REPLACE"),
              let url = URL(string: urlString), url.scheme == "https", url.host != nil
        else { return nil }
        return SupabaseConfig(url: url, anonKey: anonKey)
    }
}

public struct AuthSession: Codable, Equatable, Sendable {
    public var accessToken: String
    public var refreshToken: String
    public var userId: String
    public var expiresAt: Date

    public init(accessToken: String, refreshToken: String, userId: String, expiresAt: Date) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.userId = userId
        self.expiresAt = expiresAt
    }
}

/// Where the session is remembered between launches. The app uses UserDefaults; tests use memory.
public protocol SessionStore: Sendable {
    func load() -> AuthSession?
    func save(_ session: AuthSession?)
}

public final class InMemorySessionStore: SessionStore, @unchecked Sendable {
    private var value: AuthSession?
    private let lock = NSLock()
    public init(_ initial: AuthSession? = nil) { value = initial }
    public func load() -> AuthSession? { lock.lock(); defer { lock.unlock() }; return value }
    public func save(_ session: AuthSession?) { lock.lock(); value = session; lock.unlock() }
}

public final class UserDefaultsSessionStore: SessionStore, @unchecked Sendable {
    private let key: String
    private let defaults: UserDefaults
    public init(key: String = "waypoint.supabase.session", defaults: UserDefaults = .standard) {
        self.key = key
        self.defaults = defaults
    }
    public func load() -> AuthSession? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(AuthSession.self, from: $0) }
    }
    public func save(_ session: AuthSession?) {
        if let session, let data = try? JSONEncoder().encode(session) {
            defaults.set(data, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}

public enum CloudError: Error, Equatable {
    case notConfigured
    case http(status: Int, message: String)
    case decoding(String)
    case rejected(String)
}

/// One row of the `buildings` table. A building is identified by (owner, mapId): every contributor
/// has their OWN row for the same logical map (`mapId`), and clients merge them locally. That is how
/// "anyone can extend a building's map" works without anyone editing someone else's row.
public struct BuildingRow: Codable, Equatable, Sendable {
    public var rowId: UUID?          // server generated; omitted on insert
    public var mapId: UUID
    public var owner: UUID?          // server fills with auth.uid(); omitted on insert
    public var name: String
    public var version: Int
    public var map: BuildingMap
    public var isShared: Bool
    public var updatedAt: String?

    public init(rowId: UUID? = nil, mapId: UUID, owner: UUID? = nil, name: String, version: Int,
                map: BuildingMap, isShared: Bool, updatedAt: String? = nil) {
        self.rowId = rowId
        self.mapId = mapId
        self.owner = owner
        self.name = name
        self.version = version
        self.map = map
        self.isShared = isShared
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case rowId = "id", mapId = "map_id", owner, name, version
        case map = "map_json", isShared = "is_shared", updatedAt = "updated_at"
    }
}

/// A building row visible to this user, plus whether it is theirs.
public struct RemoteMap: Identifiable, Equatable, Sendable {
    public var row: BuildingRow
    public var isMine: Bool
    public var id: String { "\(row.owner?.uuidString ?? "?")/\(row.mapId.uuidString)" }

    public init(row: BuildingRow, isMine: Bool) {
        self.row = row
        self.isMine = isMine
    }
}
