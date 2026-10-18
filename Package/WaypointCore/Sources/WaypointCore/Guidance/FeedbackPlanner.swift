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
// Speech:   `.critical` CUTS OFF whatever is being said and is reserved for a STOP obstacle or a lost position - nothing else, because an interrupt
//           also discards the route instruction the user was about to hear. `.high` QUEUES and is used for anything the user must not miss (arrival,
//           turns, hazards, cautions, phone posture, first position fix, warnings within 5 m); `.normal` is SKIPPED while the voice is busy and is
//           used only for chatter (route briefing, landmarks, far warnings, "Position found").
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

public enum SpeechPriority: Equatable, Comparable, Sendable {
    /// Safety: cuts off whatever is being said, right now. Only an obstacle at STOP range, or losing
    /// position, earns this - everything else can wait a second.
    case critical
    /// Queued behind whatever is being said, and spoken in turn. Turns and arrival live here: while
    /// walking, several of these can fall due at once, and interrupting each with the next is what
    /// chopped them into fragments (device report 2026-10-17).
    case high
    /// Ambient. Skipped entirely if something is already being said; it will come round again.
    case normal

    /// Higher means more important. Declared explicitly rather than relying on declaration order, so
    /// adding a case later cannot silently reorder guidance.
    var rank: Int {
        switch self {
        case .critical: return 2
        case .high: return 1
        case .normal: return 0
        }
    }

    public static func < (a: SpeechPriority, b: SpeechPriority) -> Bool { a.rank < b.rank }
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

/// What to undo if a line the planner emitted never reached the user's ears (see `FeedbackPlanner.lineLost`).
public enum Rearm: Equatable, Sendable {
    case none
    /// The direction cue ("Continue straight", "Turn right"): announce the CURRENT one again.
    case direction
    /// A corner announced from the route's geometry.
    case corner(UUID)
    /// A countdown line ("In 5 meters, turn right."), by its de-duplication key.
    case warning(String)
    case landmark(UUID)
    case hazard
}

/// Bookkeeping the planner keeps per spoken line, for whoever performs the actions.
public struct LineInfo: Equatable, Sendable {
    public var rearm: Rearm
    /// Present only for lines that may be reworded by `Narration` (never for anything urgent).
    public var narration: NarrationFact?
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

    /// "Narrow space" is announced at most this often.
    public static let narrowRepeatSeconds: TimeInterval = 20

    /// Once the destination is reached the planner says nothing else (no lost-tracking, obstacle or posture chatter) until `reset()`.
    private var hasArrived = false
    private var pendingBriefing: String?
    private var narrowActive = false
    private var lastNarrowSpeech: TimeInterval?
    private var lastKey: String?
    private var lastHazardTarget: UUID?
    private var lastObstacle: ObstacleLevel = .clear
    private var lastObstacleKind: ObstacleKind?
    private var lastObstacleSpeech: TimeInterval?
    private var lastDirectionSpeech: TimeInterval?
    private var lastTrackingOK = true
    /// Have we EVER had a position this session? Distinguishes "still finding you" from "lost you";
    /// see step 1. Starts false and is set the first tick tracking is healthy.
    private var hasBeenTracking = false
    private var briefed = false
    private var announcedWarnings: Set<String> = []
    private var announcedLandmarks: Set<UUID> = []
    private var announcedCorners: Set<UUID> = []
    /// A turn we have just announced at the corner. While the user physically turns, the live bearing
    /// swings and the heading cue would announce the SAME turn again with a different angle, so we
    /// stay quiet about that direction until they are going straight again.
    private var turnInProgress: GuidanceInstruction.Kind?
    /// The "you will need to open it" line has been said for the door we are standing at.
    private var announcedWayThrough = false
    /// The way round the current obstacle has been suggested. Re-armed when the way is clear.
    private var announcedAvoidance = false
    /// The last few spoken lines and what they were (newest last), so a LOST line can be said again and a line can be offered for rewording.
    private var lineLog: [(text: String, info: LineInfo)] = []
    private static let lineLogLimit = 16

    public init() {}

    /// Forget what was announced (call when a new navigation starts).
    public mutating func reset() {
        hasArrived = false
        pendingBriefing = nil
        narrowActive = false
        lastNarrowSpeech = nil
        lastKey = nil
        lastHazardTarget = nil
        lastObstacle = .clear
        lastObstacleKind = nil
        lastObstacleSpeech = nil
        lastDirectionSpeech = nil
        lastTrackingOK = true
        hasBeenTracking = false
        briefed = false
        announcedWarnings = []
        announcedLandmarks = []
        announcedCorners = []
        turnInProgress = nil
        announcedWayThrough = false
        announcedAvoidance = false
        lineLog = []
    }

    /// What the planner knows about a line it emitted (nil for a line it did not emit, or one that is too old).
    public func info(for text: String) -> LineInfo? { lineLog.last(where: { $0.text == text })?.info }

    /// A line the planner emitted was thrown away before it was spoken (replaced, or too old by the time the voice was free).
    /// The planner had already recorded it as announced, so without this it would never be said: a turn simply vanished (device findings
    /// F-1/F-7, 2026-10-18). This forgets that it was announced; if the situation still holds, the next tick says it again.
    public mutating func lineLost(_ text: String) {
        guard let info = info(for: text) else { return }
        switch info.rearm {
        case .none: break
        case .direction:
            lastKey = nil
            lastDirectionSpeech = nil
            turnInProgress = nil
        case .corner(let id):
            announcedCorners.remove(id)
            lastKey = nil
            lastDirectionSpeech = nil
            turnInProgress = nil
        case .warning(let key): announcedWarnings.remove(key)
        case .landmark(let id): announcedLandmarks.remove(id)
        case .hazard: lastHazardTarget = nil
        }
    }

    private mutating func note(_ text: String, _ rearm: Rearm, narration: NarrationKind? = nil) {
        lineLog.append((text, LineInfo(rearm: rearm, narration: narration.map { NarrationFact(kind: $0, plain: text) })))
        if lineLog.count > Self.lineLogLimit { lineLog.removeFirst(lineLog.count - Self.lineLogLimit) }
    }

    /// The opening message ("You are near Room 206 ... Room 204 is about 25 meters away ..."), spoken instead of the plain route briefing the
    /// first time guidance runs. Built by `StartBriefing`. Cleared by `reset()`, so a re-route does not repeat it.
    public mutating func queueBriefing(_ text: String) { pendingBriefing = text }

    public mutating func plan(
        instruction: GuidanceInstruction?,
        obstacle: ObstacleLevel,
        trackingOK: Bool,
        posture: PostureUpdate? = nil,
        report: ObstacleReport? = nil,
        time: TimeInterval? = nil,
        context: SceneContext? = nil,
        isMoving: Bool? = nil,
        avoidTowards: Side? = nil,
        backUp: Bool = false
    ) -> [FeedbackAction] {
        var actions: [FeedbackAction] = []

        // 0. Arrived earlier: stay quiet. Losing tracking or seeing the door at the destination must not produce warnings after "You have arrived".
        if hasArrived {
            return [.beacon(nil)]
        }

        // 1. No position: say it once, silence the beacon, issue nothing else.
        // LOSING a position and never having had one are different events and must not share a
        // sentence. `lastTrackingOK` starts true, so the first untracked tick of a walk announced
        // "Lost my position" before there was anything to lose - alarming, and flatly untrue (heard at
        // 0:06 of the recorded walk, 2026-10-18, while the screen correctly read "Finding your
        // position"). Only a real loss is `.critical`; first acquisition is routine and queues.
        guard trackingOK else {
            if lastTrackingOK {
                if hasBeenTracking {
                    actions.append(.speak("Lost my position. Hold still.", priority: .critical))
                } else {
                    actions.append(.speak("Finding your position. Stand still, then turn slowly.", priority: .high))
                }
            }
            lastTrackingOK = false
            actions.append(.beacon(nil))
            return actions
        }
        hasBeenTracking = true
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
            hasArrived = true
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
        // A CHANGE OF KIND only counts as news while the user is actually moving. Standing in front of
        // one wall, the classifier flickers between what it thinks it is seeing - wall, then unknown,
        // then table - and each flip looked like a brand new obstacle, so the warning was re-issued
        // every tick. Each re-issue is `.critical`, so it cut off the one before it: "Stop. Stop. Stop.
        // Stop." and only the last one finished its sentence (device report 2026-10-18). If the user has
        // neither walked nor turned, the scene in front of them cannot have changed, so a different
        // answer from the classifier is noise, not news. `isMoving` covers turning on the spot too.
        // A change of LEVEL is deliberately NOT gated this way: an escalation to STOP must always be
        // heard, including when somebody walks into a stationary user's path.
        let kindChanged = obstacle != .clear && report != nil && report?.kind != lastObstacleKind
            && (isMoving ?? true)
        // Repeating a STOP only helps while the user is still moving toward the thing. Standing in
        // front of a closed door being told "stop, a door ahead" every three seconds is noise, and it
        // drowns out the one line that matters - that the door has to be opened (device report
        // 2026-10-17). `isMoving == false` silences the repeat; nil means "we cannot tell", which
        // behaves as before.
        let stillApproaching = (isMoving ?? true)
        let repeatDue = obstacle == .stop && !levelChanged && !kindChanged && stillApproaching
            && !wayThrough
            && time != nil && lastObstacleSpeech != nil && (time! - lastObstacleSpeech!) >= Self.stopRepeatSeconds
        if obstacle != .clear, levelChanged || kindChanged || repeatDue {
            if wayThrough {
                // Once per door. It is an instruction ("open it"), not a hazard to keep warning about.
                if !announcedWayThrough {
                    announcedWayThrough = true
                    actions.append(.speak(ObstacleSpeech.wayThrough(report, targetLabel: instruction?.targetLabel),
                                          priority: .high))
                    actions.append(.haptic(.obstacleCaution))
                }
            } else {
                // A way round, with the reason - "Slightly left, there is a wall ahead." Said once per
                // obstacle, right after the warning, and only when the sides were actually measured.
                // It SUGGESTS: the depth sensor cannot promise the floor that way is safe, so the
                // stop warning below is never replaced by it (see AvoidanceAdvisor).
                if let avoidTowards, !announcedAvoidance,
                   let text = TurnSpeech.avoidance(side: avoidTowards, obstacle: report?.kind) {
                    announcedAvoidance = true
                    actions.append(.speak(text, priority: .high))
                } else if backUp, !announcedAvoidance {
                    // Blocked ahead with no usable side (`AvoidanceAdvisor.isBoxedIn`). Saying only
                    // "Stop." leaves the user standing in front of a wall with nothing to do, which is
                    // exactly what was reported on the phone (F-5, 2026-10-18). Same latch as the way
                    // round above, so it is offered once per obstacle rather than nagged.
                    announcedAvoidance = true
                    actions.append(.speak(TurnSpeech.backUp, priority: .high))
                }
                // ONE way round, not two: when `AvoidanceAdvisor` (U2) has a suggestion ("Slightly left, there is a wall ahead.") the plain
                // surroundings hint ("Open space on your left.") stays quiet; it only speaks when the advisor has no clear side to suggest.
                let hintContext = avoidTowards == nil ? context : nil
                switch obstacle {
                case .stop:
                    actions.append(.speak(Self.withHint(ObstacleSpeech.stop(report), report, hintContext), priority: .critical))
                    if levelChanged || repeatDue { actions.append(.haptic(.obstacleStop)) }
                case .caution:
                    // `.high`, NOT `.critical`. A caution is "there is a table two steps ahead", not
                    // "stop walking" - and `.critical` means cut off whatever is being said, which is
                    // reserved for a STOP obstacle or a lost position (see `SpeechPriority.critical`).
                    // Marking cautions critical broke that contract twice over in a cluttered room: each
                    // one chopped the previous sentence into fragments ("Careful. An obstacle. Careful.
                    // Careful. An obstacle ahead. Careful." - recorded walk 2026-10-18) and each one
                    // wiped the queued route instruction, so no turn was ever spoken (F-1, F-7).
                    actions.append(.speak(Self.withHint(ObstacleSpeech.caution(report), report, hintContext), priority: .high))
                    if levelChanged { actions.append(.haptic(.obstacleCaution)) }
                case .clear:
                    break
                }
            }
            lastObstacleSpeech = time ?? lastObstacleSpeech
        }
        lastObstacleKind = (obstacle == .clear) ? nil : (report?.kind ?? lastObstacleKind)
        if obstacle == .clear {
            announcedWayThrough = false // through it (or it moved): arm for the next one
            announcedAvoidance = false
        }
        lastObstacle = obstacle
        // Keep guiding toward a door/stairs we are meant to go through; only a real obstacle silences
        // the beacon and stops everything else.
        if obstacle == .stop, !wayThrough {
            actions.append(.beacon(nil))
            return actions
        }

        // 2b. Narrow space (from the side clearances): say it once, then only now and then.
        if let c = context, c.isNarrow {
            let due = lastNarrowSpeech.map { (time ?? 0) - $0 >= Self.narrowRepeatSeconds } ?? true
            if !narrowActive, due {
                actions.append(.speak("Narrow space. Go slowly.", priority: .normal))
                lastNarrowSpeech = time ?? lastNarrowSpeech
            }
            narrowActive = true
        } else if context != nil {
            narrowActive = false
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
        // Never brief somebody who is facing the wrong way: "walk straight about 8 metres, then turn
        // left" is nonsense until they have turned around, and it directly contradicts the turn-around
        // cue they are being given at the same moment (device report 2026-10-17). The briefing waits.
        if !briefed, i.kind != .arrived, i.kind != .turnAround {
            briefed = true
            if let opening = pendingBriefing {
                // The full opening (where you are, what is around, how to go). High priority so the "Navigating to ..." line cannot swallow it.
                pendingBriefing = nil
                // The briefing already covers the next maneuver and the place you are standing at: do not repeat them in the same breath
                // ("...then turn right. In 9 meters, turn right. Door to lobby on your left." was heard on the phone 2026-10-17).
                if let u = i.upcoming {
                    for t in Self.warningThresholds where u.distanceMeters <= t { announcedWarnings.insert("\(u.nodeId)-\(t)") }
                }
                if let l = i.landmark { announcedLandmarks.insert(l.nodeId) }
                actions.append(.speak(opening, priority: .high))
                note(opening, .none, narration: .opening)
                if i.kind == .continueStraight { lastKey = i.kind.rawValue }
            } else if let text = ManeuverSpeech.briefing(distanceToFirstManeuver: i.upcoming) {
                actions.append(.speak(text, priority: .normal))
                note(text, .none, narration: .briefing)
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
                    let line = TurnSpeech.withDestination(text, destination: i.destinationLabel)
                    actions.append(.speak(line, priority: .high))
                    note(line, .corner(corner.nodeId))
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
                // All direction cues are `.high` so they QUEUE. "Continue straight." used to be
                // `.normal`, which SpeechGate drops whenever the speaker is busy - and it always is
                // right after a turn. The planner had already recorded it as announced, so the cue
                // telling the user to carry on was lost every single time (reported 2026-10-17).
                let line = TurnSpeech.withDestination(text, destination: i.destinationLabel)
                actions.append(.speak(line, priority: .high))
                note(line, .direction)
            }
            }
        }
        if let hazard = i.hazard {
            if lastHazardTarget != i.targetNodeId {
                lastHazardTarget = i.targetNodeId
                actions.append(.speak(Self.hazardText(hazard), priority: .high))
                note(Self.hazardText(hazard), .hazard)
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
                    let line = ManeuverSpeech.warning(u)
                    actions.append(.speak(line, priority: t <= 5 ? .high : .normal))
                    // Only the far countdown may be reworded; within 5 m it is a timing cue and goes out as written.
                    note(line, .warning(key), narration: t > 5 ? .countdown : nil)
                }
            }
        }

        // 4d. Landmarks as they are passed.
        if let l = i.landmark, !announcedLandmarks.contains(l.nodeId) {
            announcedLandmarks.insert(l.nodeId)
            let line = ManeuverSpeech.landmark(label: l.label, side: l.side)
            actions.append(.speak(line, priority: .normal))
            note(line, .landmark(l.nodeId), narration: .landmark)
        }

        actions.append(.beacon(i.kind == .arrived ? nil : i.targetPosition))
        return actions
    }

    /// Appends the way-out hint from the surroundings, if there is one.
    static func withHint(_ sentence: String, _ report: ObstacleReport?, _ context: SceneContext?) -> String {
        guard let hint = SceneAdvice.hint(for: report, context: context) else { return sentence }
        return sentence + " " + hint
    }

    static func hazardText(_ h: Hazard) -> String {
        switch h {
        case .stairs: return "Stairs ahead."
        case .narrow: return "Narrow passage ahead."
        case .doorThreshold: return "Raised threshold ahead."
        }
    }
}
