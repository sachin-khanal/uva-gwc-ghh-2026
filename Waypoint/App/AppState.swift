//
// File:     Waypoint/App/AppState.swift
// Owner:    D (App/Sync/Integration)
// Purpose:  App-wide observable state: which mode the user picked (volunteer / navigator), the
//           on-disk `MapStore`, the list of maps, and a stable device name for `createdBy`.
//           Only REAL scanned maps live in the store. (Until 2026-10-18 the first launch seeded a hand-written sample map; that is gone, and
//           launch removes a copy that an older build already seeded.)
// Threading: UI-only class, always touched from the main thread.
//
import SwiftUI
import WaypointCore

final class AppState: ObservableObject {

    enum Mode { case none, volunteer, navigator }

    @Published var mode: Mode = .none
    @Published private(set) var maps: [BuildingMap] = []

    let store: MapStore

    /// "iPhone-ab12": iOS hides the real device name from apps, so we add 4 chars of the vendor id
    /// to tell phones apart in `MapNode.createdBy` and in Multipeer peer names.
    let deviceName: String

    /// Self-test switch from launch arguments (see LaunchCommand). `.none` in normal use.
    let launchCommand = LaunchCommand.fromLaunchArguments()

    /// Supabase library (D). Disabled automatically when no URL/key is configured.
    let cloud: CloudController

    init() {
        if let store = try? MapStore.defaultStore() {
            self.store = store
        } else {
            // Extremely unlikely; keep the app usable (maps just will not survive a relaunch).
            self.store = MapStore(rootURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("Maps", isDirectory: true))
            Log.app.error("Documents directory unavailable; using temporary store")
        }
        let short = UIDevice.current.identifierForVendor?.uuidString.prefix(4).lowercased() ?? "0000"
        self.deviceName = "\(UIDevice.current.model)-\(short)"
        self.cloud = CloudController(store: self.store)
        cloud.onImported = { [weak self] _ in self?.reloadMaps() }

        removeSeededSampleMap()
        reloadMaps()

        switch launchCommand {
        case .simulate: mode = .navigator
        case .scan: mode = .volunteer
        case .none, .e2e: break
        }
        if launchCommand.isActive { Log.app.info("launch command: \(launchCommand)") }
    }

    func reloadMaps() {
        maps = (try? store.listMaps()) ?? []
        Log.app.info("loaded \(self.maps.count) map(s)")
    }

    /// Deletes a recording: the map JSON, its ARWorldMap files, and the per-map UI state that would
    /// otherwise outlive it (recent destinations, and a pending "try it in Navigate" hand-off).
    ///
    /// Deliberately NOT touched: copies on other phones or in the cloud. Deleting here is local only,
    /// which is what the confirmation text promises.
    /// - Returns: true when the map is gone from disk.
    @discardableResult
    func deleteMap(_ map: BuildingMap) -> Bool {
        do {
            try store.delete(id: map.id)
        } catch {
            Log.app.error("delete failed for \(map.name): \(error.localizedDescription)")
            reloadMaps()
            return false
        }
        // Stale per-map keys would otherwise accumulate, and a map re-imported under the same id
        // would resurrect someone else's recent destinations.
        UserDefaults.standard.removeObject(forKey: UIPrefs.recentsKey(mapId: map.id))
        if UserDefaults.standard.string(forKey: UIPrefs.pendingMapId) == map.id.uuidString {
            UserDefaults.standard.removeObject(forKey: UIPrefs.pendingMapId)
        }
        Log.app.info("deleted map \(map.name)")
        reloadMaps()
        return true
    }

    /// Older builds copied a hand-written "SAMPLE - Fake Rice Hall corridor" map into the store on first launch. It is a placeholder, not a scan,
    /// so remove it once (matched by its fixed id; scanned maps always get fresh random ids).
    private func removeSeededSampleMap() {
        guard let sampleId = UUID(uuidString: "5A3E0000-0000-4000-8000-000000000001"),
              (try? store.listMaps().contains { $0.id == sampleId }) == true else { return }
        try? store.delete(id: sampleId)
        if UserDefaults.standard.string(forKey: UIPrefs.pendingMapId) == sampleId.uuidString {
            UserDefaults.standard.removeObject(forKey: UIPrefs.pendingMapId)
        }
        Log.app.info("removed the old bundled sample map")
    }
}
