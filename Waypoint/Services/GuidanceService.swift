//
// File:     Waypoint/Services/GuidanceService.swift
// Owner:    U3 (UI flows)
// Purpose:  The seam between the new Navigator screens and whatever guides the user (docs/UI_PLAN.md §2.1):
//           `MockGuidanceService` (silent scripted timeline) or `LiveGuidanceService` (the existing
//           NavigationController, real or simulated). Screens only see `GuidanceSnapshot` (WaypointCore).
// One voice rule: when `speaksForItself` is true, NavigationController's SpeechGuide already speaks every
//           instruction, so the UI must NOT announce the same text again (UI_PLAN §7 principle 6).
// Threading: every method and `onUpdate` callback runs on the MAIN thread.
// Status:   SCAFFOLD.
//
import WaypointCore

protocol GuidanceService: AnyObject {
    var onUpdate: ((GuidanceSnapshot) -> Void)? { get set }
    var snapshot: GuidanceSnapshot { get }
    /// True when the service speaks instructions itself (live / simulated).
    var speaksForItself: Bool { get }
    /// Pause/resume is only possible in the mock for now.
    var supportsPause: Bool { get }
    /// Escort-panel tools that only the mock can fake (force lost, fail, skip).
    var supportsDebugControls: Bool { get }
    /// True when an obstacle can be injected (mock and simulated walk).
    var supportsObstacleInjection: Bool { get }

    /// - Parameter start: where the route starts if the real position is unknown (mock only; the live
    ///   controller always uses the user's real position, the simulated walker the first breadcrumb).
    func start(map: BuildingMap, destination: MapNode, from start: MapNode?)
    func pause()
    func resume()
    func stop()

    // Escort / debug tools.
    func injectObstacle(_ on: Bool)
    func forceLost(_ on: Bool)
    func forceFailure()
    func skipToArrival()
}
