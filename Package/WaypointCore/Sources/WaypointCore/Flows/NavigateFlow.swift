//
// File:     Flows/NavigateFlow.swift
// Module:   WaypointCore
// Owner:    U3 (UI flows)
// Purpose:  State machine for the new Navigator (blind user) workflow (docs/UI_PLAN.md §3, §7):
//           building -> destination -> confirm -> active (localizing / guiding) -> arrived.
//           Rules that matter for a blind user live here so they are unit-tested:
//             * a single map is picked automatically (one less screen to listen to),
//             * a back/escape gesture never ends an ACTIVE route (no accidental exits),
//             * "route back" from arrival goes to confirm, not straight into guidance.
// Status:   DONE (logic), tested in FlowTests.
//
import Foundation

public enum NavStep: String, Equatable, Sendable {
    case building, destination, confirm, active, arrived
}

public struct NavigateFlow: Equatable, Sendable {

    public private(set) var step: NavStep
    public let mapCount: Int

    public init(mapCount: Int) {
        self.mapCount = mapCount
        self.step = mapCount == 1 ? .destination : .building
    }

    public mutating func chooseMap() { if step == .building { step = .destination } }
    public mutating func chooseDestination() { if step == .destination { step = .confirm } }
    public mutating func start() { if step == .confirm { step = .active } }
    public mutating func arrive() { if step == .active { step = .arrived } }
    /// Stopping an active route returns to the destination list.
    public mutating func stop() { if step == .active { step = .destination } }
    public mutating func newDestination() { if step == .arrived { step = .destination } }
    public mutating func routeBack() { if step == .arrived { step = .confirm } }

    /// Back / VoiceOver escape. Returns false when the caller should leave Navigate mode entirely.
    /// While a route is active the gesture is swallowed (returns true, nothing changes).
    @discardableResult
    public mutating func back() -> Bool {
        switch step {
        case .confirm:
            step = .destination
            return true
        case .destination:
            if mapCount > 1 {
                step = .building
                return true
            }
            return false
        case .active:
            return true
        case .building, .arrived:
            return false
        }
    }

    /// Where a route starts when the real position is not known yet (route preview, mock and simulated
    /// walks): the first breadcrumb, which is where the volunteer started scanning. Matches
    /// `NavigationController.startSimulation`. Never returns the destination itself.
    public static func defaultStart(in map: BuildingMap, excluding excluded: UUID?) -> MapNode? {
        map.nodes.first { $0.kind == .corridor && $0.id != excluded }
            ?? map.nodes.first { $0.id != excluded }
    }
}
