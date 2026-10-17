//
// File:     Waypoint/Guidance/HapticsGuide.swift
// Owner:    B (Navigation/Feedback)
// Purpose:  Plays the `HapticCue`s chosen by FeedbackPlanner using CoreHaptics.
// Note:     An iPhone has ONE Taptic Engine, so "left" and "right" cannot be spatial. We encode
//           direction in the PATTERN instead: left = 1 sharp tap, right = 2 sharp taps. Teach
//           this at the start of the demo ("one tap means left, two taps means right").
// Status:   SCAFFOLD. TODO(B): tune intensities on a real phone; consider a rising pulse rate
//           that tracks obstacle distance instead of a single caution/stop buzz.
//
import CoreHaptics
import WaypointCore

final class HapticsGuide {

    private var engine: CHHapticEngine?

    init() {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else {
            Log.guidance.info("haptics not supported on this device")
            return
        }
        do {
            let engine = try CHHapticEngine()
            engine.isAutoShutdownEnabled = true
            // If iOS stops the engine (e.g. app backgrounded), restart it lazily on next play().
            engine.stoppedHandler = { reason in Log.guidance.info("haptic engine stopped: \(reason.rawValue)") }
            engine.resetHandler = { [weak engine] in try? engine?.start() }
            self.engine = engine
        } catch {
            Log.guidance.error("haptic engine init failed: \(error.localizedDescription)")
        }
    }

    func play(_ cue: HapticCue) {
        guard let engine else { return }
        do {
            try engine.start()
            let pattern = try CHHapticPattern(events: Self.events(for: cue), parameters: [])
            let player = try engine.makePlayer(with: pattern)
            try player.start(atTime: CHHapticTimeImmediate)
        } catch {
            Log.guidance.error("haptic play failed: \(error.localizedDescription)")
        }
    }

    // MARK: Patterns

    private static func tap(at t: TimeInterval, intensity: Float, sharpness: Float) -> CHHapticEvent {
        CHHapticEvent(eventType: .hapticTransient, parameters: [
            CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
            CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness),
        ], relativeTime: t)
    }

    private static func buzz(at t: TimeInterval, duration: TimeInterval, intensity: Float) -> CHHapticEvent {
        CHHapticEvent(eventType: .hapticContinuous, parameters: [
            CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
            CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.3),
        ], relativeTime: t, duration: duration)
    }

    private static func events(for cue: HapticCue) -> [CHHapticEvent] {
        switch cue {
        case .turnLeft:
            return [tap(at: 0, intensity: 1, sharpness: 1)]
        case .turnRight:
            return [tap(at: 0, intensity: 1, sharpness: 1), tap(at: 0.15, intensity: 1, sharpness: 1)]
        case .obstacleCaution:
            return [0, 0.12, 0.24].map { tap(at: $0, intensity: 0.5, sharpness: 0.3) }
        case .obstacleStop:
            return [buzz(at: 0, duration: 0.7, intensity: 1)]
        case .holdPhoneUpright:
            // Three firm, quick, sharp taps: "fix how you are holding the phone" (distinct from the 1-tap left / 2-tap right turn cues).
            return [0, 0.12, 0.24].map { tap(at: $0, intensity: 1, sharpness: 0.9) }
        case .arrived:
            return [tap(at: 0, intensity: 0.8, sharpness: 0.5),
                    buzz(at: 0.2, duration: 0.4, intensity: 0.6),
                    tap(at: 0.7, intensity: 1, sharpness: 1)]
        }
    }
}
