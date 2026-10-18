//
// File:     Waypoint/Guidance/SpeechGuide.swift
// Owner:    B (Navigation/Feedback)
// Purpose:  Speaks FeedbackPlanner's `.speak` actions.
// Update 2026-10-17: this class NO LONGER owns an AVSpeechSynthesizer. It forwards to `Speaker`, the
//           single voice of the app, because owning a second synthesizer meant the UI's `Announcer`
//           and this class spoke over each other at arrival (D-026). The priority and repeat rules
//           moved to `SpeechGate` in WaypointCore, where they are unit-tested.
// Note:     This is separate from VoiceOver. Navigator mode keeps working with VoiceOver off.
// Status:   SCAFFOLD. TODO(B): speech rate setting; optionally duck the beacon while speaking.
//
import WaypointCore

final class SpeechGuide {

    func say(_ text: String, priority: SpeechPriority, staysFresh: Bool = false) {
        Speaker.shared.say(text, priority: priority, staysFresh: staysFresh)
    }

    /// Tell `handler` (main thread) whenever a line was thrown away before it was heard. Cleared by `stop()`'s owner via `nil`.
    func onLineLost(_ handler: ((String) -> Void)?) {
        Speaker.shared.onLineLost = handler
    }

    func stop() {
        Speaker.shared.stop()
    }
}
