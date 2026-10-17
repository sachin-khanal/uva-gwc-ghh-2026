//
// File:     Flows/ScanFlow.swift
// Module:   WaypointCore
// Owner:    U3 (UI flows)
// Purpose:  Pure logic behind the new Scanner (volunteer) workflow screens (docs/UI_PLAN.md §3, §6):
//             * `ScanFlow`    - which screen is showing and which moves between screens are allowed.
//             * `ScanQuality` - our own copy of ARKit's WorldMappingStatus so screens never import ARKit.
//             * `ScanTracking`- tracking state parsed from CaptureController.trackingSummary (observe-only).
//             * `FinishGate`  - when "Finish" is enabled, and the sentence explaining why not.
// Why here: no SwiftUI/ARKit, so `make test` and CI prove it without a phone.
// Status:   DONE (logic), tested in FlowTests.
//
import Foundation

/// The screens of the Scanner workflow, in order.
public enum ScanStep: String, Equatable, Sendable {
    case library, setup, scanning, review, share
}

/// State machine for the Scanner workflow. Illegal moves are ignored (never crash on a double tap).
public struct ScanFlow: Equatable, Sendable {

    public private(set) var step: ScanStep = .library

    public init() {}

    public mutating func newScan() { if step == .library { step = .setup } }
    public mutating func startScanning() { if step == .setup { step = .scanning } }
    public mutating func finishScanning() { if step == .scanning { step = .review } }
    public mutating func discardScan() { if step == .scanning { step = .library } }
    /// Library -> Review of an existing map (no scanning).
    public mutating func openReview() { if step == .library { step = .review } }
    public mutating func share() { if step == .review { step = .share } }
    public mutating func done() { if step == .review || step == .share { step = .library } }

    /// Back navigation. Returns false when there is nowhere to go back to inside the flow
    /// (library) or when going back is not allowed (scanning: the user must Finish or Discard).
    @discardableResult
    public mutating func back() -> Bool {
        switch step {
        case .setup, .review:
            step = .library
            return true
        case .share:
            step = .review
            return true
        case .library, .scanning:
            return false
        }
    }
}

/// How well ARKit has mapped the area. Mirrors `ARFrame.WorldMappingStatus`.
public enum ScanQuality: Int, Equatable, CaseIterable, Sendable {
    case notAvailable = 0
    case limited = 1
    case extending = 2
    case mapped = 3

    /// 0...1 for the progress ring.
    public var progress: Double {
        switch self {
        case .notAvailable: return 0
        case .limited: return 0.25
        case .extending: return 0.6
        case .mapped: return 1
        }
    }

    public var word: String {
        switch self {
        case .notAvailable: return "Not started"
        case .limited: return "Limited"
        case .extending: return "Extending"
        case .mapped: return "Mapped"
        }
    }
}

/// Camera tracking state as the Scanner screens show it.
public enum ScanTracking: Equatable, Sendable {
    case starting
    case normal
    /// Limited tracking; the string is a short user-facing reason ("Moving too fast").
    case limited(String)
    case unavailable

    /// Parses `CaptureController.trackingSummary` (see `CaptureController.describe`). Keeping this
    /// mapping here means a wording change in CaptureController breaks a test, not the UI.
    public static func from(summary: String) -> ScanTracking {
        switch summary {
        case "Tracking OK": return .normal
        case "Tracking unavailable": return .unavailable
        case "Not started": return .starting
        default:
            return summary.hasPrefix("Initializing") ? .starting : .limited(summary)
        }
    }

    public var isNormal: Bool { self == .normal }

    public var word: String {
        switch self {
        case .starting: return "Starting"
        case .normal: return "Tracking OK"
        case .limited(let reason): return reason
        case .unavailable: return "Tracking unavailable"
        }
    }
}

/// Whether the volunteer may finish (save) the scan.
public enum FinishGate: Equatable, Sendable {
    case ready
    /// Not yet; the string tells the volunteer what to do.
    case blocked(String)

    /// Rule: ARKit must report the area as mapped (a world map saved earlier relocalizes badly) AND
    /// at least one labelled place must be tagged, otherwise a blind user has nowhere to go.
    public static func evaluate(quality: ScanQuality, labelledTagCount: Int) -> FinishGate {
        if quality != .mapped { return .blocked("Keep walking slowly until mapping is complete.") }
        if labelledTagCount == 0 { return .blocked("Tag at least one room or door with a label.") }
        return .ready
    }

    public var isReady: Bool { self == .ready }

    public var reason: String? {
        if case .blocked(let text) = self { return text }
        return nil
    }
}
