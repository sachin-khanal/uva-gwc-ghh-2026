//
// File:     Waypoint/App/AppState.swift
// Owner:    D (App/Sync/Integration)
// Purpose:  App-wide observable state: which mode the user picked (volunteer / navigator), the
//           on-disk `MapStore`, the list of maps, and a stable device name for `createdBy`.
//           On first launch it copies Samples/rice-hall-sample.json (bundled as a resource) into
//           the store so B and C can test navigation WITHOUT having scanned anything.
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

        seedSampleMapIfNeeded()
        reloadMaps()
    }

    func reloadMaps() {
        maps = (try? store.listMaps()) ?? []
        Log.app.info("loaded \(self.maps.count) map(s)")
    }

    /// Copies the bundled sample map into the store once (only when the store is empty).
    private func seedSampleMapIfNeeded() {
        guard (try? store.listMaps().isEmpty) == true,
              let url = Bundle.main.url(forResource: "rice-hall-sample", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let map = try? BuildingMap.from(jsonData: data)
        else { return }
        try? store.save(map)
        Log.app.info("seeded sample map")
    }
}
