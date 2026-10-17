//
// File:     Guidance/FeedbackPlanner.swift
// Module:   WaypointCore
// Owner:    B (Navigation/Feedback)
// Purpose:  Decides WHAT the user should hear/feel, without touching any audio or haptic API.
//           Input each tick: the current `GuidanceInstruction?` (with route look-ahead and landmarks), the obstacle level from LiDAR plus an optional
//           `ObstacleReport` saying WHAT and WHERE it is, whether tracking is healthy, and how the phone is being held (`PostureUpdate`).
//           Output: a list of `FeedbackAction`s for the app target to perform (speak / vibrate / move the spatial beacon).
// Priority: lost tracking > obstacle stop > obstacle caution > phone posture > route advance warnings / turns > landmarks > ambient beacon.
//           (Posture ranks below obstacles on purpose: a wall in front of the user matters more than how the phone is held.)
// Speech:   `.high` interrupts and is used for anything the user must not miss (arrival, turns, hazards, obstacles, phone posture, lost position, warnings
//           within 5 m); `.normal` is SKIPPED while the voice is busy and is used only for chatter ("Continue straight", route briefing, landmarks,
//           far warnings, "Position found").
// Spoken guidance (accessibility requirement, 2026-10-17):
//           * route BRIEFING once at the start: "Walk straight about 12 meters, then turn right."
//           * ADVANCE WARNINGS counting down to the next turn/stairs/arrival: "In 10 meters, turn right." ... "In 5 meters ..." ... "In 2 meters ..."
//           * the turn itself when it is time: "Turn right."  (announced when the KIND of instruction changes, not at every waypoint)
//           * LANDMARKS as you pass them: "Room 206 on your right."
//           * OBSTACLES by type and place: "Stop. You are about to walk into a trash can." / "Stop. You are heading toward a wall." /
//             "Careful. A chair on your left, about 2 steps." (wording in SpokenPhrases.swift)
//           * PHONE POSTURE: "The phone is pointing down. Hold it upright, with the camera facing forward." + a distinct vibration. While the phone is
//             held wrongly, route guidance and the beacon are muted (they would be based on a wrong heading); obstacle warnings stay active.
// De-duplication: speech and haptics fire only when the situation CHANGES, never every frame. The beacon action is emitted every tick because it is
//           continuous. A STOP obstacle is repeated every 3 s while it persists (when the caller supplies `time`).
// Safety rule: when tracking is lost, an obstacle is at STOP level, or the phone posture is wrong, the beacon is muted (`.beacon(nil)`) so we never keep
//           pulling the user forward.
//
import Foundation
import simd

public enum SpeechPriority: Equatable, Sendable {
    /// Interrupts anything currently being spoken (obstacle, lost position).
    case high
    /// Waits its turn / is skipped if the synthesizer is busy.
    case normal
}

public enum HapticCue: Equatable, Sendable {
    case turnLeft        // one sharp tap
    case turnRight       // two sharp taps
    case obstacleCaution // soft triple tap
    case obstacleStop    // long strong buzz
    case arrived         // celebratory pattern
    case holdPhoneUpright // three firm, quick taps: "fix how you are holding the phone"
}

public enum FeedbackAction: Equatable, Sendable {
    case speak(String, priority: SpeechPriority)
    case haptic(HapticCue)
    /// Place the spatial-audio beacon at this MAP-frame position, or silence it with nil.
    case beacon(SIMD3<Float>?)
}

public struct FeedbackPlanner {

    /// Meters-to-go at which advance warnings are spoken (each at most once per maneuver).
    public static let warningThresholds: [Float] = [10, 5, 2]
    /// While a STOP obstacle persists, repeat the warning this often (needs `time` from the caller).
    public static let stopRepeatSeconds: TimeInterval = 3
    /// How close to a corner we are when the turn itself is announced ("Turn right 60 degrees.").
    /// The turn comes from the ROUTE's geometry, not the live bearing: with a 3 m steering lookahead
    /// the user is already easing into the corner, so the bearing never swings far enough to trip the
    /// heading cue, and a real turn would go unannounced (caught by the end-to-end walk test).
    /// Matches the countdown's own "too close for a warning" cut-off, so the sequence is
    /// 10 m / 5 m / 2 m warnings, then the turn itself at the corner.
    public static let cornerDistanceMeters: Float = 1.2
    /// While a real corner is this close, the live heading cue says nothing about turning. Easing into
    /// a corner swings the bearing past the heading cue's threshold BEFORE we reach the corner, so the
    /// same turn was announced twice: once early with the bearing's angle, once at the corner with the
    /// route's. The corner is the authoritative one; this keeps the other quiet until then.
    public static let cornerSuppressionMeters: Float = 4.0
    /// Minimum gap between two DIRECTION cues. Without it a few quick heading changes fire one after
    /// another and the user is talked at continuously instead of being given one thing to do
    /// (device report 2026-10-17). Safety messages (obstacles, lost tracking) are never delayed.
    public static let directionCooldownSeconds: TimeInterval = 1.5

    private var lastKey: String?
    private var lastHazardTarget: UUID?
    private var lastObstacle: ObstacleLevel = .clear
    private var lastObstacleKind: ObstacleKind?
    private var lastObstacleSpeech: TimeInterval?
    private var lastDirectionSpeech: TimeInterval?
    private var lastTrackingOK = true
    private var briefed = false
    private var announcedWarnings: Set<String> = []
    private var announcedLandmarks: Set<UUID> = []
    private var announcedCorners: Set<UUID> = []
    /// A turn we have just announced at the corner. While the user physically turns, the live bearing
    /// swings and the heading cue would announce the SAME turn again with a different angle, so we
    /// stay quiet about that direction until they are going straight again.
    private var turnInProgress: GuidanceInstruction.Kind?

    public init() {}

    /// Forget what was announced (call when a new navigation starts).
    public mutating func reset() {
        lastKey = nil
        lastHazardTarget = nil
        lastObstacle = .clear
        lastObstacleKind = nil
        lastObstacleSpeech = nil
        lastDirectionSpeech = nil
        lastTrackingOK = true
        briefed = false
        announcedWarnings = []
        announcedLandmarks = []
        announcedCorners = []
        turnInProgress = nil
    }

    public mutating func plan(
        instruction: GuidanceInstruction?,
        obstacle: ObstacleLevel,
        trackingOK: Bool,
        posture: PostureUpdate? = nil,
        report: ObstacleReport? = nil,
        time: TimeInterval? = nil
    ) -> [FeedbackAction] {
        var actions: [FeedbackAction] = []

        // 1. Lost tracking: say it once, silence the beacon, issue nothing else.
        guard trackingOK else {
            if lastTrackingOK {
                actions.append(.speak("Lost my position. Hold still.", priority: .high))
            }
            lastTrackingOK = false
            actions.append(.beacon(nil))
            return actions
        }
        if !lastTrackingOK {
            actions.append(.speak("Position found.", priority: .normal))
            lastTrackingOK = true
            lastKey = nil // re-announce the current instruction after recovering
            lastHazardTarget = nil
        }

        // 1b. ARRIVAL outranks everything below. At the destination the thing the depth sensor sees is
        // usually the destination itself (the door you were walking to), so letting the obstacle branch
        // run first produced "Stop. You are about to walk into a door." and the arrival was never
        // announced at all - the `return` in the obstacle branch swallowed it (found on device
        // 2026-10-17). Once arrived there is nothing left to steer, so we say it once, mute the beacon
        // and stay quiet.
        if let i = instruction, i.kind == .arrived {
            if lastKey != i.kind.rawValue {
                lastKey = i.kind.rawValue
                actions.append(.speak(ArrivalSpeech.text(kind: i.targetKind, label: i.targetLabel), priority: .high))
                actions.append(.haptic(.arrived))
            }
            // Keep the obstacle bookkeeping honest so nothing is re-announced if guidance restarts.
            lastObstacle = obstacle
            lastObstacleKind = (obstacle == .clear) ? nil : (report?.kind ?? lastObstacleKind)
            actions.append(.beacon(nil))
            return actions
        }

        // 2. Obstacles: say WHAT and WHERE when the level or the kind of thing changes, and keep reminding while STOP persists.
        // Is the thing ahead the way IN rather than something to avoid? (door of the target room,
        // the stairs we routed to). If so it gets instructions, not an alarm, and guidance continues.
        let wayThrough = RouteFeature.isWayThrough(obstacle: report?.kind, target: instruction?.targetKind)
        let levelChanged = obstacle != lastObstacle
        let kindChanged = obstacle != .clear && report != nil && report?.kind != lastObstacleKind
        let repeatDue = obstacle == .stop && !levelChanged && !kindChanged
            && time != nil && lastObstacleSpeech != nil && (time! - lastObstacleSpeech!) >= Self.stopRepeatSeconds
        if obstacle != .clear, levelChanged || kindChanged || repeatDue {
            if wayThrough {
                actions.append(.speak(ObstacleSpeech.wayThrough(report, targetLabel: instruction?.targetLabel),
                                      priority: .high))
                if levelChanged { actions.append(.haptic(.obstacleCaution)) }
            } else {
                switch obstacle {
                case .stop:
                    actions.append(.speak(ObstacleSpeech.stop(report), priority: .high))
                    if levelChanged || repeatDue { actions.append(.haptic(.obstacleStop)) }
                case .caution:
                    actions.append(.speak(ObstacleSpeech.caution(report), priority: .high))
                    if levelChanged { actions.append(.haptic(.obstacleCaution)) }
                case .clear:
                    break
                }
            }
            lastObstacleSpeech = time ?? lastObstacleSpeech
        }
        lastObstacleKind = (obstacle == .clear) ? nil : (report?.kind ?? lastObstacleKind)
        lastObstacle = obstacle
        // Keep guiding toward a door/stairs we are meant to go through; only a real obstacle silences
        // the beacon and stops everything else.
        if obstacle == .stop, !wayThrough {
            actions.append(.beacon(nil))
            return actions
        }

        // 3. Phone posture: tell the user, and stop guiding from a heading we cannot trust.
        if let p = posture {
            if let text = p.announcement {
                if p.issue != nil {
                    actions.append(.speak(text, priority: .high))
                    actions.append(.haptic(.holdPhoneUpright))
                } else if p.recovered {
                    // Say ONLY the confirmation on this tick; guidance resumes (and re-announces the current instruction) on the next one, so the
                    // user hears "Phone position is good." and then the direction, not both piled on top of each other.
                    actions.append(.speak(text, priority: .normal))
                    lastKey = nil
                    actions.append(.beacon(nil))
                    return actions
                }
            }
            if p.issue != nil {
                actions.append(.beacon(nil))
                return actions
            }
        }

        // 4. Navigation instruction.
        guard let i = instruction else {
            actions.append(.beacon(nil))
            return actions
        }

        // 4a. Route briefing, once: how far to the first turn/stairs/destination. Replaces the first "Continue straight."
        if !briefed, i.kind != .arrived {
            briefed = true
            if let text = ManeuverSpeech.briefing(distanceToFirstManeuver: i.upcoming) {
                actions.append(.speak(text, priority: .normal))
                if i.kind == .continueStraight { lastKey = i.kind.rawValue }
            }
        }

        // 4b. Announce when the KIND of instruction changes (straight -> turn right -> straight ...), NOT every time the target waypoint advances:
        // real scans have a node every 1.5 m, and keying on the target made "Continue straight." repeat at every one (found by the on-phone
        // end-to-end test, 2026-10-17). Hazards are announced once per hazardous target, below.
        // A corner from the route's own geometry outranks the live heading cue.
        let corner: Maneuver? = {
            guard let u = i.upcoming, u.kind == .turnLeft || u.kind == .turnRight,
                  u.distanceMeters <= Self.cornerDistanceMeters,
                  !announcedCorners.contains(u.nodeId) else { return nil }
            return u
        }()
        let key = corner.map { "corner-\($0.nodeId)" } ?? i.kind.rawValue
        // One direction at a time: hold a new cue back until the cooldown has passed. `lastKey` is
        // deliberately NOT updated while holding, so the cue is announced on a later tick instead of
        // being lost.
        let cooledDown: Bool = {
            guard let now = time, let last = lastDirectionSpeech else { return true }
            return now - last >= Self.directionCooldownSeconds
        }()
        // A real corner is coming and has not been announced yet: let IT do the talking.
        let waitingForCorner: Bool = {
            guard corner == nil, i.kind == .turnLeft || i.kind == .turnRight,
                  let u = i.upcoming, u.kind == .turnLeft || u.kind == .turnRight,
                  !announcedCorners.contains(u.nodeId),
                  u.distanceMeters <= Self.cornerSuppressionMeters else { return false }
            // Only when it is the SAME way we are drifting; a genuine wrong-way cue still gets through.
            return (u.kind == .turnRight) == (i.kind == .turnRight)
        }()
        // Already turning the way we just told them to: say nothing more about it.
        let repeatsCornerJustAnnounced = (corner == nil && i.kind == turnInProgress)
        if i.kind == .continueStraight { turnInProgress = nil }

        if key != lastKey, cooledDown, !repeatsCornerJustAnnounced, !waitingForCorner {
            lastKey = key
            lastDirectionSpeech = time ?? lastDirectionSpeech
            if let corner {
                announcedCorners.insert(corner.nodeId)
                // The countdown ("in 5 metres, turn right") has had its say; do not repeat it now.
                for t in Self.warningThresholds { announcedWarnings.insert("\(corner.nodeId)-\(t)") }
                let kind: GuidanceInstruction.Kind = corner.kind == .turnRight ? .turnRight : .turnLeft
                // Pretend the heading cue already said this. As the user physically turns, the live
                // bearing swings and the heading cue would otherwise announce the SAME turn a second
                // time, a moment later and with a different angle.
                lastKey = kind.rawValue
                turnInProgress = kind
                actions.append(.haptic(kind == .turnRight ? .turnRight : .turnLeft))
                if let text = TurnSpeech.text(kind: kind, bearingRadians: corner.angleRadians ?? 0) {
                    actions.append(.speak(text, priority: .high))
                }
            } else {
            switch i.kind {
            case .arrived:
                break // unreachable: handled in step 1b, before obstacles can pre-empt it
            case .turnLeft:
                actions.append(.haptic(.turnLeft))
            case .turnRight:
                actions.append(.haptic(.turnRight))
            case .turnAround, .continueStraight:
                break
            }
            if let text = TurnSpeech.text(kind: i.kind, bearingRadians: i.bearingRadians) {
                actions.append(.speak(text, priority: i.kind == .continueStraight ? .normal : .high))
            }
            }
        }
        if let hazard = i.hazard {
            if lastHazardTarget != i.targetNodeId {
                lastHazardTarget = i.targetNodeId
                actions.append(.speak(Self.hazardText(hazard), priority: .high))
            }
        } else {
            lastHazardTarget = nil
        }

        // 4c. Countdown to the next maneuver: once at 10 m, 5 m and 2 m (the smallest threshold already passed; never a burst).
        if i.kind != .arrived, let u = i.upcoming {
            if u.distanceMeters < 1.2 {
                for t in Self.warningThresholds { announcedWarnings.insert("\(u.nodeId)-\(t)") } // too close: the turn cue itself covers it
            } else if let t = Self.warningThresholds.filter({ u.distanceMeters <= $0 }).min() {
                let key = "\(u.nodeId)-\(t)"
                if !announcedWarnings.contains(key) {
                    for larger in Self.warningThresholds where larger >= t { announcedWarnings.insert("\(u.nodeId)-\(larger)") }
                    actions.append(.speak(ManeuverSpeech.warning(u), priority: t <= 5 ? .high : .normal))
                }
            }
        }

        // 4d. Landmarks as they are passed.
        if let l = i.landmark, !announcedLandmarks.contains(l.nodeId) {
            announcedLandmarks.insert(l.nodeId)
            actions.append(.speak(ManeuverSpeech.landmark(label: l.label, side: l.side), priority: .normal))
        }

        actions.append(.beacon(i.kind == .arrived ? nil : i.targetPosition))
        return actions
    }

    static func hazardText(_ h: Hazard) -> String {
        switch h {
        case .stairs: return "Stairs ahead."
        case .narrow: return "Narrow passage ahead."
        case .doorThreshold: return "Raised threshold ahead."
        }
    }
}
