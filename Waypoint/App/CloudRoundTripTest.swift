//
// File:     Waypoint/App/CloudRoundTripTest.swift
// Owner:    D (cloud) / U3
// Purpose:  OPT-IN live test of shared map data against the real Supabase project (`-e2eCloudWrite YES` on top of `-autoE2E YES`, i.e.
//           `make selftest-e2e EXTRA=...` style launch). Two DIFFERENT anonymous users play the volunteers:
//             A publishes a small map + a scan file  ->  A and B both see it  ->  B downloads it byte-for-byte  ->  B extends it
//             (new node, new scan segment)  ->  A sees the extension  ->  A re-uploads its STALE copy and B's extension must survive
//             ->  5 list+download cycles are timed to show whether it is reliable.
// WRITES:   one building named "ZZ CONNECTION TEST <time> (safe to delete)" and 2 small scan files. The shared `canonical_buildings` table
//           has NO delete for app users (migration 0002 revokes it), so the row stays until someone runs, in the Supabase SQL editor:
//               delete from public.canonical_buildings where name like 'ZZ CONNECTION TEST%';
//           Never runs unless the launch argument is present.
// Status:   SCAFFOLD, new. UNVERIFIED until run.
//
import Foundation
import QuartzCore
import WaypointCore

enum CloudRoundTripTest {

    static var requested: Bool { UserDefaults.standard.bool(forKey: "e2eCloudWrite") }

    /// `report(name, ok, detail)`; returns nothing, every outcome goes through `report`.
    static func run(config: SupabaseConfig, report: (String, Bool, String) -> Void) async {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let name = "ZZ CONNECTION TEST \(stamp) (safe to delete)"
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("cloudtest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let storeA = MapStore(rootURL: scratch.appendingPathComponent("A"))
        let storeB = MapStore(rootURL: scratch.appendingPathComponent("B"))
        let clientA = SupabaseClient(config: config, sessionStore: InMemorySessionStore())
        let clientB = SupabaseClient(config: config, sessionStore: InMemorySessionStore())
        let engineA = SyncEngine(client: clientA, store: storeA)
        let engineB = SyncEngine(client: clientB, store: storeB)

        do {
            let a = try await clientA.ensureSession(), b = try await clientB.ensureSession()
            report("cloudrt.twoUsers", a.userId != b.userId, "A \(a.userId.prefix(6)) vs B \(b.userId.prefix(6))")

            // A's map: 3 corridor nodes 1.5 m apart, one scan segment with 4 KB of random "world map" bytes.
            let n1 = MapNode(kind: .corridor, position: [0, 0, 0], segmentId: "seg1", createdBy: "cloudtest-A")
            let n2 = MapNode(kind: .room, label: "Test Room 1", position: [0, 0, -1.5], segmentId: "seg1", createdBy: "cloudtest-A")
            let n3 = MapNode(kind: .corridor, position: [0, 0, -3], segmentId: "seg1", createdBy: "cloudtest-A")
            let map = BuildingMap(name: name, nodes: [n1, n2, n3],
                                  edges: [MapEdge(from: n1.id, to: n2.id, distance: 1.5), MapEdge(from: n2.id, to: n3.id, distance: 1.5)])
            let scanA = Data((0..<4096).map { _ in UInt8.random(in: 0...255) })
            try storeA.save(map)
            try storeA.saveWorldMap(scanA, mapId: map.id, segmentId: "seg1")

            var t = CACurrentMediaTime()
            try await engineA.push(mapId: map.id, share: true)
            report("cloudrt.publish", true, "A published in \(ms(since: t)) ms")

            let seenByA = try await engineA.listRemote().first { $0.row.mapId == map.id }
            report("cloudrt.visibleToOwner", seenByA != nil && seenByA?.row.map.nodes.count == 3, "A lists it, \(seenByA?.row.map.nodes.count ?? -1) nodes")

            t = CACurrentMediaTime()
            let seenByB = try await engineB.listRemote().first { $0.row.mapId == map.id }
            report("cloudrt.visibleToOtherUser", seenByB != nil, "B (a different user) lists it in \(ms(since: t)) ms")
            guard let remoteForB = seenByB else { return }

            t = CACurrentMediaTime()
            let bundleB = try await engineB.fetchBundle(remoteForB)
            report("cloudrt.downloadIdentical", bundleB.map.nodes.count == 3 && bundleB.worldMaps["seg1"] == scanA,
                   "B downloaded \(bundleB.worldMaps["seg1"]?.count ?? 0) scan bytes (sent \(scanA.count)) in \(ms(since: t)) ms")

            // B extends: imports the map, adds a node attached to the last node in a NEW scan segment, and publishes.
            _ = try storeB.importBundle(bundleB)
            var extended = try storeB.load(id: map.id)
            let n4 = MapNode(kind: .room, label: "Test Room 2", position: [0, 0, -4.5], segmentId: "seg2", createdBy: "cloudtest-B")
            extended.nodes.append(n4)
            extended.edges.append(MapEdge(from: n3.id, to: n4.id, distance: 1.5))
            let scanB = Data((0..<2048).map { _ in UInt8.random(in: 0...255) })
            try storeB.save(extended)
            try storeB.saveWorldMap(scanB, mapId: map.id, segmentId: "seg2")
            t = CACurrentMediaTime()
            try await engineB.push(mapId: map.id, share: true)
            report("cloudrt.extendByOtherUser", true, "B published its extension in \(ms(since: t)) ms")

            let afterA = try await engineA.listRemote().first { $0.row.mapId == map.id }
            report("cloudrt.extensionVisibleToOwner", afterA?.row.map.nodes.count == 4 && (afterA?.row.version ?? 0) > (seenByA?.row.version ?? 0),
                   "A sees \(afterA?.row.map.nodes.count ?? -1) nodes, version \(seenByA?.row.version ?? -1) -> \(afterA?.row.version ?? -1)")
            if let afterA {
                let full = try await engineA.fetchBundle(afterA)
                report("cloudrt.contributorScanFileReachable", full.worldMaps["seg2"] == scanB && full.worldMaps["seg1"] == scanA,
                       "A downloaded both segments: seg1 \(full.worldMaps["seg1"]?.count ?? 0) B, seg2 \(full.worldMaps["seg2"]?.count ?? 0) B")
            }

            // A is stale (still has 3 nodes): re-uploading must not erase B's work.
            try await engineA.push(mapId: map.id, share: true)
            let finalRow = try await engineB.listRemote().first { $0.row.mapId == map.id }
            report("cloudrt.staleUploadKeepsExtension", finalRow?.row.map.nodes.count == 4, "after A's stale re-upload: \(finalRow?.row.map.nodes.count ?? -1) nodes")

            // Reliability: repeated list + download. Every cycle must succeed and return identical data.
            var times: [Double] = [], failures = 0
            for _ in 0..<5 {
                let start = CACurrentMediaTime()
                do {
                    guard let r = try await engineB.listRemote().first(where: { $0.row.mapId == map.id }) else { failures += 1; continue }
                    let bundle = try await engineB.fetchBundle(r)
                    if bundle.worldMaps["seg1"] != scanA || bundle.worldMaps["seg2"] != scanB || bundle.map.nodes.count != 4 { failures += 1 }
                } catch { failures += 1 }
                times.append(Double(ms(since: start)))
            }
            let avg = times.reduce(0, +) / Double(max(1, times.count))
            report("cloudrt.reliability5x", failures == 0,
                   "5 list+download cycles, \(failures) failed, ms min/avg/max = \(Int(times.min() ?? 0))/\(Int(avg))/\(Int(times.max() ?? 0))")
        } catch {
            report("cloudrt.error", false, "\(error)")
        }
    }

    private static func ms(since t: CFTimeInterval) -> Int { Int((CACurrentMediaTime() - t) * 1000) }
}
