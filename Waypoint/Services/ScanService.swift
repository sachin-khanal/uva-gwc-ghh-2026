//
// File:     Waypoint/Services/ScanService.swift
// Owner:    U3 (UI flows)
// Purpose:  The seam between the new Scanner screens and whatever does the scanning (docs/UI_PLAN.md §2.1).
//           Screens only see `ScanSnapshot` (our own value types, no ARKit enums), so they run identically on
//           the mock (`MockScanService`) and the real engine (`LiveScanService` -> CaptureController).
// Threading: every method and `onUpdate` callback runs on the MAIN thread.
// Status:   SCAFFOLD.
//
import ARKit
import WaypointCore

/// A place the volunteer tagged during this scan.
struct ScanTag: Identifiable, Equatable {
    let id: UUID
    var kind: NodeKind
    var label: String?

    var hasLabel: Bool { !(label ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
}

/// Everything the scanning screen shows, as one value.
struct ScanSnapshot: Equatable {
    var isRunning = false
    var tracking: ScanTracking = .starting
    var quality: ScanQuality = .notAvailable
    var nodeCount = 0
    var triangleCount = 0
    /// Size of the scan bounding box in metres (x, y, z), once there is a mesh.
    var boxSize: SIMD3<Float>?
    var boxMargin: Float = 0.1
    var tags: [ScanTag] = []
    /// A label read from a sign, offered as a one-tap tag (slot for SignReader, ROADMAP U2.7).
    var suggestion: String?
    var errorMessage: String?

    var labelledTagCount: Int { tags.filter(\.hasLabel).count }
    var finishGate: FinishGate { FinishGate.evaluate(quality: quality, labelledTagCount: labelledTagCount) }
}

protocol ScanService: AnyObject {
    /// Called on the main thread whenever the snapshot changes.
    var onUpdate: ((ScanSnapshot) -> Void)? { get set }
    var snapshot: ScanSnapshot { get }
    /// True for demo data (shows the "Demo data" badge and the placeholder camera).
    var isMock: Bool { get }
    /// The AR session to render with `LiveScanView`, nil for the mock.
    var arSession: ARSession? { get }
    var scanBox: OrientedBox? { get }

    func start(mapName: String)
    /// Pause/resume recording. The live adapter can only stop accepting tags (see LiveScanService).
    func pause()
    func resume()
    func tag(kind: NodeKind, label: String?)
    func dismissSuggestion()
    func adjustBox(by delta: Float)
    /// Saves the map; completion on the main thread.
    func finish(completion: @escaping (Result<BuildingMap, Error>) -> Void)
    func cancel()
}

struct ScanServiceError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
