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

/// A place already labelled in the map being EXTENDED, that the volunteer can say they are standing at.
/// Carries no position: the screen only needs to show a name and send the id back.
struct StandPlace: Identifiable, Equatable {
    let id: UUID
    var label: String
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
    /// 0...1: how much of the walk has been seen from BOTH directions (D-043).
    var returnCoverage: Float = 0
    /// Ask the volunteer to walk back the way they came.
    var shouldWalkBack = false
    var tags: [ScanTag] = []
    /// A label read from a sign, offered as a one-tap tag (slot for SignReader, ROADMAP U2.7).
    var suggestion: String?
    var errorMessage: String?
    /// Recording is really paused (live engine): no breadcrumbs, tags or mesh counting; the camera keeps tracking.
    var isPaused = false
    /// "Show unscanned areas" is on, and the share of the box surfaces already covered by mesh (nil until the first measurement).
    var showCoverage = false
    var coveragePercent: Float?
    /// Extending a saved map: what the scanner is waiting for / doing ("Look around slowly...", "Extending this building..."), nil for a new scan.
    var extensionStatus: String?
    /// False while an extension is still finding its place in the saved area (recording and tagging are paused).
    var canRecord = true
    /// Stairwell / lift names already used in this map, offered when tagging another one so the two ends
    /// of one staircase end up with the SAME name (that is how floors are matched).
    var knownStairwellNames: [String] = []
    /// Extending a saved map: the labelled places the volunteer can confirm standing at, so they can locate
    /// themselves BY HAND instead of waiting for ARKit to recognise the space. Empty for a new scan.
    var placesToStandAt: [StandPlace] = []
    /// How many of those have been confirmed (0 or 1). Two solves the alignment and attaches.
    var confirmedPlaceCount = 0
    /// The place already confirmed, so the screen can tick it and stop it being tapped twice.
    var confirmedPlaceId: UUID?

    var labelledTagCount: Int { tags.filter(\.hasLabel).count }
    var finishGate: FinishGate { FinishGate.evaluate(quality: quality, labelledTagCount: labelledTagCount,
                                                       extensionPending: extensionStatus != nil && !canRecord) }
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
    /// Extend a saved map: relocalize in `initialSegment`'s world map, then record new nodes attached to it. Only the live engine can; the
    /// default (mock) just starts a demo scan.
    func start(mapName: String, extending map: BuildingMap?, initialSegment: String?)
    /// Pause/resume recording. The live adapter can only stop accepting tags (see LiveScanService).
    func pause()
    /// May refuse (live engine): resuming far from where recording was paused is not allowed. Check `snapshot.isPaused` afterwards.
    func resume()
    /// The yellow "unscanned areas" overlay data for LiveScanView, nil when off / unavailable.
    var coverageOverlay: CoverageSnapshot? { get }
    func setShowCoverage(_ on: Bool)
    func tag(kind: NodeKind, label: String?)
    /// Tag a staircase or lift, with what the volunteer could see: which way it goes, where the handrail
    /// is, roughly how many steps. ARKit's mesh classification has no railing class, so this is the only
    /// source for any of it. No default implementation on purpose - see `confirmPlace`.
    func tagStairs(kind: NodeKind, label: String?, info: StairsInfo)
    /// "I am standing at this labelled place" while extending a map. Two of them, a few metres apart, locate
    /// the phone in the saved map without ARKit having to recognise the space. Only the live engine can act
    /// on it; the mock implements it as a no-op EXPLICITLY.
    ///
    /// Deliberately has NO default implementation in the extension below. A no-op default here silently
    /// swallowed a real bug: `LiveScanService`'s version was accidentally nested inside another method, so
    /// it was not the protocol witness, the default ran instead, and tapping a place did nothing at all -
    /// with no compiler complaint (device report 2026-10-18). Requiring every conformer to say what it does
    /// turns that class of mistake back into a build error.
    func confirmPlace(id: UUID)
    /// Forget the places confirmed so far. There is always a way out of a refused alignment.
    func restartPlaceConfirmation()
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

extension ScanService {
    func start(mapName: String, extending map: BuildingMap?, initialSegment: String?) { start(mapName: mapName) }
}
