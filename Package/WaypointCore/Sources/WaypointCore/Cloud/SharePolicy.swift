//
// File:     Cloud/SharePolicy.swift
// Module:   WaypointCore
// Owner:    D (cloud/sync) with A (scan)
// Purpose:  Decides whether a saved map may LEAVE this phone. The Supabase buckets (and `MapBundle.validate()` on the receiving side) cap a
//           single scan file at 50,000,000 bytes. A scan's ARWorldMap grows quickly (27.5 MB for 5.5 m x 3.3 m on a real phone), so a longer
//           hallway can pass the cap. Rule (Sachin, 2026-10-18): a map whose scan file is over the cap is NOT uploaded and NOT sent to a nearby
//           phone; it stays on this phone only, and the person is told why. Saving it locally must keep working (`MapStore.saveLocalScan`).
// Inputs:   file sizes only (bytes per scan segment), so the check never loads a 50 MB file into memory.
// Status:   DONE (logic, unit tested). Enforced in SyncEngine.push, MapSync.send, SyncView and shown on the review screen.
//
import Foundation

public enum SharePolicy {

    /// Largest scan file the cloud bucket and an incoming bundle accept (matches migration 0001 and `MapBundle.maxWorldMapBytes`).
    public static let limitBytes = ExportBudget.supabaseFreeTierFileLimit
    /// Above this the person gets a heads-up that a longer scan will no longer be shareable.
    public static let warnBytes = 40_000_000

    public enum Verdict: Equatable, Sendable {
        case ok
        /// Still shareable, but close to the cap.
        case nearLimit(bytes: Int)
        /// Over the cap: keep on this phone only.
        case localOnly(segment: String, bytes: Int)

        public var isLocalOnly: Bool { if case .localOnly = self { return true } else { return false } }
    }

    /// - Parameter worldMapBytes: size in bytes of each scan segment's world map file, by segment id.
    public static func evaluate(worldMapBytes: [String: Int]) -> Verdict {
        // Largest file decides; ties broken by segment id so the answer is deterministic.
        guard let top = worldMapBytes.sorted(by: { ($0.value, $1.key) > ($1.value, $0.key) }).first else { return .ok }
        if top.value > limitBytes { return .localOnly(segment: top.key, bytes: top.value) }
        if top.value > warnBytes { return .nearLimit(bytes: top.value) }
        return .ok
    }

    /// "27.5 MB" (decimal megabytes, the unit the 50 MB cap is in).
    public static func megabytes(_ bytes: Int) -> String { String(format: "%.1f MB", Double(bytes) / 1_000_000) }

    /// A sentence for the person, or nil when there is nothing to say.
    public static func message(_ verdict: Verdict) -> String? {
        switch verdict {
        case .ok:
            return nil
        case .nearLimit(let bytes):
            return "This scan is \(megabytes(bytes)). Scans over \(megabytes(limitBytes)) cannot be shared to the cloud or to nearby phones, so a longer scan would stay on this phone."
        case .localOnly(_, let bytes):
            return "This scan is \(megabytes(bytes)), over the \(megabytes(limitBytes)) sharing limit, so it stays on this phone only. It still works for navigation here. To share it, scan in shorter parts."
        }
    }
}
