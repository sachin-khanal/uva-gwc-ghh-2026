//
// File:     Guidance/FeedbackPlanner.swift
// Module:   WaypointCore
// Owner:    B (Navigation/Feedback)
// Purpose:  Decides WHAT the user should hear/feel, without touching any audio or haptic API.
//           Input each tick: current `GuidanceInstruction?`, the obstacle level from LiDAR, and
//           whether tracking is healthy. Output: a list of `FeedbackAction`s for the app target to
//           perform (speak / vibrate / move the spatial beacon).
// Priority (Architecture.md 4.4): lost-tracking > obstacle stop > obstacle caution > hazard >
//           turn > ambient beacon.
// De-duplication: speech and haptics fire only when the situation CHANGES (new target or new kind),
//           never every frame. The beacon action is emitted every tick because it is continuous.
// Safety rule: when tracking is lost or an obstacle is at STOP level the beacon is muted
//           (`.beacon(nil)`) so we never keep pulling the user forward.
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
}

public enum FeedbackAction: Equatable, Sendable {
    case speak(String, priority: SpeechPriority)
    case haptic(HapticCue)
    /// Place the spatial-audio beacon at this MAP-frame position, or silence it with nil.
    case beacon(SIMD3<Float>?)
}

public struct FeedbackPlanner {

    private var lastKey: String?
    private var lastObstacle: ObstacleLevel = .clear
    private var lastTrackingOK = true

    public init() {}

    /// Forget what was announced (call when a new navigation starts).
    public mutating func reset() {
        lastKey = nil
        lastObstacle = .clear
        lastTrackingOK = true
    }

    public mutating func plan(
        instruction: GuidanceInstruction?,
        obstacle: ObstacleLevel,
        trackingOK: Bool
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
        }

        // 2. Obstacles: announce on level change only.
        if obstacle != lastObstacle {
            switch obstacle {
            case .stop:
                actions.append(.speak("Stop. Obstacle ahead.", priority: .high))
                actions.append(.haptic(.obstacleStop))
            case .caution:
                actions.append(.speak("Obstacle ahead.", priority: .normal))
                actions.append(.haptic(.obstacleCaution))
            case .clear:
                break
            }
            lastObstacle = obstacle
        }
        if obstacle == .stop {
            actions.append(.beacon(nil))
            return actions
        }

        // 3. Navigation instruction.
        guard let i = instruction else {
            actions.append(.beacon(nil))
            return actions
        }

        let key = "\(i.kind.rawValue)-\(i.targetNodeId.uuidString)"
        if key != lastKey {
            lastKey = key
            switch i.kind {
            case .arrived:
                let where_ = i.targetLabel.map { " at \($0)" } ?? ""
                actions.append(.speak("You have arrived\(where_).", priority: .normal))
                actions.append(.haptic(.arrived))
            case .turnLeft:
                actions.append(.haptic(.turnLeft))
                actions.append(.speak("Turn left.", priority: .normal))
            case .turnRight:
                actions.append(.haptic(.turnRight))
                actions.append(.speak("Turn right.", priority: .normal))
            case .turnAround:
                actions.append(.speak("Turn around.", priority: .normal))
            case .continueStraight:
                actions.append(.speak("Continue straight.", priority: .normal))
            }
            if let hazard = i.hazard {
                actions.append(.speak(Self.hazardText(hazard), priority: .normal))
            }
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
