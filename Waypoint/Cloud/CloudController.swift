//
// File:     Waypoint/Cloud/CloudController.swift
// Owner:    D (App/Sync/Integration)
// Purpose:  UI-facing wrapper around WaypointCore's `SyncEngine` / `SupabaseClient`:
//             * reads the project URL + anon key from Info.plist (set in Config/Local.xcconfig),
//             * upload ("push") a local map, optionally shared with everyone,
//             * refresh the remote library, download a map.
//           Your own maps import straight away; maps owned by SOMEONE ELSE are held in
//           `pendingDownload` until the user taps Import (decisions D-012 / D-015: cloud data is untrusted).
// Offline:  every method fails soft with a message in `status`; navigation never depends on this class.
// Status:   SCAFFOLD, UNVERIFIED ON DEVICE and UNVERIFIED AGAINST A REAL SUPABASE PROJECT. The HTTP layer
//           itself is covered by CloudTests (mock transport). First real test: enable Anonymous Sign-Ins,
//           run supabase/migrations/0001_init.sql, set the two xcconfig values, tap Upload.
//
import Foundation
import WaypointCore

final class CloudController: ObservableObject {

    struct PendingDownload: Identifiable {
        let id = UUID()
        let remote: RemoteMap
        let bundle: MapBundle
        var summary: String {
            "\"\(bundle.map.name)\": \(bundle.map.nodes.count) places, \(bundle.map.edges.count) connections, "
            + "\(bundle.worldMaps.count) scan file(s)"
        }
    }

    @Published private(set) var status = "Cloud not checked yet"
    @Published private(set) var remote: [RemoteMap] = []
    @Published private(set) var isBusy = false
    @Published private(set) var pendingDownload: PendingDownload?

    /// Called on the main queue after a map was written into the local store.
    var onImported: ((BuildingMap) -> Void)?

    let isConfigured: Bool
    private let store: MapStore
    private let engine: SyncEngine?

    init(store: MapStore, bundle: Bundle = .main) {
        self.store = store
        let config = SupabaseConfig.validated(
            urlString: bundle.object(forInfoDictionaryKey: "SupabaseURL") as? String,
            anonKey: bundle.object(forInfoDictionaryKey: "SupabaseAnonKey") as? String)
        if let config {
            let client = SupabaseClient(config: config, sessionStore: KeychainSessionStore())
            engine = SyncEngine(client: client, store: store)
            isConfigured = true
            status = "Cloud ready"
        } else {
            engine = nil
            isConfigured = false
            status = "Cloud not configured (see docs/SETUP.md, Supabase section)"
        }
    }

    // MARK: Actions

    func push(mapId: UUID, name: String, share: Bool) {
        run("Uploading \(name)...") { engine in
            try await engine.push(mapId: mapId, share: share)
            return "Uploaded \(name)" + (share ? " (shared)" : " (private)")
        }
    }

    func refresh() {
        guard let engine else { return }
        isBusy = true
        status = "Loading library..."
        Task { @MainActor in
            defer { self.isBusy = false }
            do {
                self.remote = try await engine.listRemote()
                self.status = "Library: \(self.remote.count) map(s)"
            } catch {
                self.status = Self.describe(error)
                Log.sync.error("cloud refresh failed: \(error.localizedDescription)")
            }
        }
    }

    func download(_ item: RemoteMap) {
        guard let engine else { return }
        isBusy = true
        status = "Downloading \(item.row.name)..."
        Task { @MainActor in
            defer { self.isBusy = false }
            do {
                let bundle = try await engine.fetchBundle(item)
                if item.isMine {
                    self.finishImport(bundle)
                } else {
                    self.pendingDownload = PendingDownload(remote: item, bundle: bundle)
                    self.status = "Review \(item.row.name) before importing"
                }
            } catch {
                self.status = Self.describe(error)
                Log.sync.error("cloud download failed: \(error.localizedDescription)")
            }
        }
    }

    func respondToPendingDownload(accept: Bool) {
        guard let pending = pendingDownload else { return }
        pendingDownload = nil
        if accept { finishImport(pending.bundle) } else { status = "Rejected \(pending.remote.row.name)" }
    }

    // MARK: Private

    private func finishImport(_ bundle: MapBundle) {
        do {
            let map = try store.importBundle(bundle)
            status = "Imported \(map.name)"
            onImported?(map)
        } catch MapStoreError.rejected(let reason) {
            status = "Refused map: \(reason)"
        } catch {
            status = "Import failed: \(error.localizedDescription)"
        }
    }

    private func run(_ message: String, _ work: @escaping (SyncEngine) async throws -> String) {
        guard let engine else { return }
        isBusy = true
        status = message
        Task { @MainActor in
            defer { self.isBusy = false }
            do { self.status = try await work(engine) }
            catch {
                self.status = Self.describe(error)
                Log.sync.error("cloud op failed: \(error.localizedDescription)")
            }
        }
    }

    private static func describe(_ error: Error) -> String {
        switch error {
        case CloudError.http(let status, let message):
            if status == 401 || status == 403 { return "Cloud denied access (\(status)). Check Anonymous Sign-Ins and the SQL policies." }
            return "Cloud error \(status): \(message)"
        case CloudError.rejected(let reason): return "Refused map: \(reason)"
        case MapStoreError.rejected(let reason): return "Refused map: \(reason)"
        case is URLError: return "No connection to the cloud (offline?)."
        default: return "Cloud failed: \(error.localizedDescription)"
        }
    }
}
