//
// File:     Guidance/PhonePosture.swift
// Module:   WaypointCore
// Owner:    B (Navigation/Feedback) - accessibility requirement from U1: "phone should be held in the correct position, and the user must be informed"
// Purpose:  Watches how the phone is held and tells the user when it is wrong. Everything the app does for a blind user assumes the phone is
//           HELD UPRIGHT IN PORTRAIT, CAMERA FACING FORWARD at roughly chest height: the heading we use for turn cues is the camera's heading, the
//           obstacle detector looks at what is in front of the camera, and sign reading needs the camera pointing at walls. A phone pointing at the
//           floor, tilted up, leaning, or held sideways silently breaks all of that, so we say so (and vibrate) instead of guessing.
// Frames:   ARKit's camera transform is fixed to the SENSOR, not to the screen. For a phone held upright in portrait (verified geometry, see
//           Geometry.cameraTransform): camera +x points toward the BOTTOM of the phone, camera +y toward the user's RIGHT, and the camera looks
//           along -z. So the phone's "up" is -x and its "right" is +y.
//           pitch = angle of the viewing direction above the horizon (negative = pointing at the floor).
//           roll  = lean of the phone about the viewing direction (positive = top of the phone leans to the user's right; +-90 = sideways).
// Stability: instantaneous readings jitter with a walking hand, so the monitor uses (1) HYSTERESIS (enter a warning at 30 degrees, clear it only
//           below 20), (2) DWELL time (a bad pose must persist 0.8 s before we speak; a good pose 0.5 s before we clear), (3) rate-limited REPEATS
//           (every 8 s while still wrong) and (4) one short "Phone position is good" when fixed.
// Verified: the maths round-trips in unit tests with synthetic poses; the mapping to REAL ARKit axes is derived from Apple's documented camera
//           axes and must be confirmed on a device (hold the phone upright: the `posture:` console line should read pitch ~0, roll ~0).
//
import Foundation
import simd

public enum PostureIssue: String, Equatable, Sendable {
    case tiltedDown   // camera points at the floor
    case tiltedUp     // camera points at the ceiling
    case leaningLeft  // top of the phone leans left
    case leaningRight // top of the phone leans right
    case sideways     // held in landscape

    /// What we say. Short, concrete, tells the user what to DO.
    public var message: String {
        switch self {
        case .tiltedDown: return "The phone is pointing down. Hold it upright, with the camera facing forward."
        case .tiltedUp: return "The phone is pointing up. Hold it upright, with the camera facing forward."
        case .leaningLeft: return "The phone is leaning left. Straighten it so the screen faces you."
        case .leaningRight: return "The phone is leaning right. Straighten it so the screen faces you."
        case .sideways: return "Hold the phone upright, not sideways."
        }
    }
}

public struct PostureReading: Equatable, Sendable {
    public var pitchDegrees: Float
    public var rollDegrees: Float
    public init(pitchDegrees: Float, rollDegrees: Float) {
        self.pitchDegrees = pitchDegrees
        self.rollDegrees = rollDegrees
    }
}

public struct PostureUpdate: Equatable, Sendable {
    public var reading: PostureReading
    /// The CONFIRMED problem (after dwell + hysteresis), or nil when the phone position is good.
    public var issue: PostureIssue?
    /// Non-nil exactly on the ticks when something should be spoken now (new problem, repeat reminder, or recovery).
    public var announcement: String?
    /// True on the tick the position returns to good after having been bad.
    public var recovered: Bool
}

public struct PostureMonitor {

    // Thresholds in degrees. Pitch is asymmetric: pointing slightly up is much less harmful than pointing down at the floor.
    public var enterPitchDown: Float = 30
    public var enterPitchUp: Float = 35
    public var enterRoll: Float = 30
    public var sidewaysRoll: Float = 60
    public var exitPitchDown: Float = 20
    public var exitPitchUp: Float = 25
    public var exitRoll: Float = 20
    public var badDwell: TimeInterval = 0.8
    public var goodDwell: TimeInterval = 0.5
    public var repeatInterval: TimeInterval = 8

    public private(set) var issue: PostureIssue?
    private var candidate: PostureIssue?
    private var candidateSince: TimeInterval = 0
    private var goodSince: TimeInterval?
    private var lastAnnounced: TimeInterval?

    public init() {}

    public mutating func reset() {
        issue = nil
        candidate = nil
        goodSince = nil
        lastAnnounced = nil
    }

    /// Pitch/roll of a phone held in portrait, from ARKit's `camera.transform`. See the file header for the axis convention.
    public static func reading(cameraTransform m: simd_float4x4) -> PostureReading {
        let forward = Geometry.cameraForward(of: m)
        let phoneUp = simd_normalize(-SIMD3<Float>(m.columns.0.x, m.columns.0.y, m.columns.0.z))
        let pitch = asin(max(-1, min(1, forward.y))) * 180 / .pi

        // The "ideal" up for a camera looking along `forward` is world-up with the forward component removed.
        let worldUp = SIMD3<Float>(0, 1, 0)
        let idealUpRaw = worldUp - forward * simd_dot(worldUp, forward)
        guard simd_length(idealUpRaw) > 1e-3 else { return PostureReading(pitchDegrees: pitch, rollDegrees: 0) } // looking straight up/down
        let idealUp = simd_normalize(idealUpRaw)
        let idealRight = simd_cross(forward, idealUp)
        let roll = atan2(simd_dot(phoneUp, idealRight), simd_dot(phoneUp, idealUp)) * 180 / .pi
        return PostureReading(pitchDegrees: pitch, rollDegrees: roll)
    }

    public mutating func update(cameraTransform: simd_float4x4, time: TimeInterval) -> PostureUpdate {
        update(reading: Self.reading(cameraTransform: cameraTransform), time: time)
    }

    public mutating func update(reading: PostureReading, time: TimeInterval) -> PostureUpdate {
        let wasBad = issue != nil
        let instant = instantIssue(reading, hysteresis: wasBad)
        var announcement: String?
        var recovered = false

        if let instant {
            goodSince = nil
            if issue == instant {
                // Still the same problem: remind every `repeatInterval` seconds.
                if let last = lastAnnounced, time - last >= repeatInterval {
                    announcement = instant.message
                    lastAnnounced = time
                }
            } else {
                if candidate != instant { candidate = instant; candidateSince = time }
                if time - candidateSince >= badDwell {
                    issue = instant
                    announcement = instant.message
                    lastAnnounced = time
                    candidate = nil
                }
            }
        } else {
            candidate = nil
            if issue != nil {
                if goodSince == nil { goodSince = time }
                if time - (goodSince ?? time) >= goodDwell {
                    issue = nil
                    recovered = true
                    announcement = "Phone position is good."
                    lastAnnounced = nil
                    goodSince = nil
                }
            }
        }
        return PostureUpdate(reading: reading, issue: issue, announcement: announcement, recovered: recovered)
    }

    /// The problem right now, ignoring dwell. `hysteresis` uses the (looser) exit thresholds while a problem is already active.
    private func instantIssue(_ r: PostureReading, hysteresis: Bool) -> PostureIssue? {
        let down = hysteresis ? exitPitchDown : enterPitchDown
        let up = hysteresis ? exitPitchUp : enterPitchUp
        let roll = hysteresis ? exitRoll : enterRoll
        if r.pitchDegrees < -down { return .tiltedDown }
        if r.pitchDegrees > up { return .tiltedUp }
        if abs(r.rollDegrees) > roll {
            if abs(r.rollDegrees) > sidewaysRoll { return .sideways }
            return r.rollDegrees > 0 ? .leaningRight : .leaningLeft
        }
        return nil
    }
}
