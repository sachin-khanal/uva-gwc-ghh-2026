//
// File:     Vision/ObstacleClassifier.swift
// Module:   WaypointCore
// Owner:    C (Vision)
// Purpose:  Turns the nearest LiDAR depth reading (meters) in front of the user into a stable
//           3-level state: clear / caution / stop. Includes hysteresis so a reading hovering
//           around a threshold does not flicker between levels (which would spam the user).
// Input:    produced by Waypoint/Vision/ObstacleDetector.swift (reads the ARKit depth buffer).
// Defaults: stop below 0.6 m, caution below 1.2 m (Architecture.md 4.5). To LEAVE a level the
//           reading must exceed its threshold by `hysteresis` (0.15 m). Tune on a real phone.
//
import Foundation

public enum ObstacleLevel: Int, Equatable, Comparable, Sendable {
    case clear = 0
    case caution = 1
    case stop = 2

    public static func < (a: ObstacleLevel, b: ObstacleLevel) -> Bool { a.rawValue < b.rawValue }
}

public struct ObstacleClassifier {

    public var stopBelow: Float
    public var cautionBelow: Float
    public var hysteresis: Float
    public private(set) var level: ObstacleLevel = .clear

    public init(stopBelow: Float = 0.6, cautionBelow: Float = 1.2, hysteresis: Float = 0.15) {
        self.stopBelow = stopBelow
        self.cautionBelow = cautionBelow
        self.hysteresis = hysteresis
    }

    /// - Parameter nearest: smallest trusted depth in the forward region, or nil if no valid reading.
    ///   nil means "nothing close was measured" and is treated as clear.
    @discardableResult
    public mutating func update(nearest: Float?) -> ObstacleLevel {
        let d = nearest ?? .infinity

        // Entering a level uses the raw threshold.
        let raw: ObstacleLevel = d < stopBelow ? .stop : (d < cautionBelow ? .caution : .clear)

        if raw > level {
            level = raw
        } else if raw < level {
            // Leaving a level requires clearing its threshold plus the hysteresis margin.
            switch level {
            case .stop:
                if d >= stopBelow + hysteresis { level = raw }
            case .caution:
                if d >= cautionBelow + hysteresis { level = raw }
            case .clear:
                break
            }
        }
        return level
    }

    public mutating func reset() { level = .clear }
}
