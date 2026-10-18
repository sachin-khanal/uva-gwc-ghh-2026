//
// File:     Flows/GuidanceState.swift
// Module:   WaypointCore
// Owner:    U3 (UI flows)
// Purpose:  What the Navigator screens show and say while a route is running, independent of where it
//           comes from (mock timeline, simulated walker, or real relocalization):
//             * `GuidancePhase`    - localizing / guiding / lost / obstacle stop / arrived / failed.
//             * `GuidanceSnapshot` - one immutable frame of UI state + its headline and spoken sentence.
//           `derive(status:instruction:...)` turns NavigationController's existing published strings
//           (`statusText`, `instructionText`) into a snapshot WITHOUT changing NavigationController
//           (docs/UI_PLAN.md rule R3). If those strings change, FlowTests fail - that is intended.
// Status:   DONE (logic), tested in FlowTests.
//
import Foundation

public enum GuidancePhase: Equatable, Sendable {
    case idle
    case localizing
    case guiding
    case lost
    case obstacleStop
    case arrived
    /// Guidance could not start or continue; the string is user-presentable.
    case failed(String)
}

public struct GuidanceSnapshot: Equatable, Sendable {

    public var phase: GuidancePhase
    /// Current instruction kind while guiding.
    public var kind: GuidanceInstruction.Kind?
    /// Metres to the next route point (or to the end of the current step in the mock).
    public var distanceToNext: Float?
    /// Metres to the destination, if the source knows it (the live controller does not).
    public var distanceRemaining: Float?
    public var obstacle: ObstacleLevel
    public var destinationLabel: String
    /// Raw status from the source, for the escort panel only.
    public var rawStatus: String
    /// The line the app most recently SPOKE, when a live service is driving guidance.
    /// The screen shows this so that what is written and what is heard agree - they were derived
    /// separately and drifted apart, which is confusing when you can see and hear both
    /// (device report 2026-10-17). nil in mock mode, where the UI does the talking.
    public var lastSpoken: String?

    public init(
        phase: GuidancePhase = .idle,
        kind: GuidanceInstruction.Kind? = nil,
        distanceToNext: Float? = nil,
        distanceRemaining: Float? = nil,
        obstacle: ObstacleLevel = .clear,
        destinationLabel: String = "",
        rawStatus: String = ""
    ) {
        self.phase = phase
        self.kind = kind
        self.distanceToNext = distanceToNext
        self.distanceRemaining = distanceRemaining
        self.obstacle = obstacle
        self.destinationLabel = destinationLabel
        self.rawStatus = rawStatus
    }

    public static let idle = GuidanceSnapshot()

    // MARK: Text

    /// The big words on the guiding screen.
    public var headline: String {
        switch phase {
        case .idle: return "Ready"
        case .localizing: return "Finding your position"
        case .guiding:
            // Prefer the words actually spoken, so the screen is not a paraphrase of the voice - but
            // only when they are a short DIRECTIVE. A briefing ("Walk straight about 8 metres, then
            // turn left.") is narration: as a headline it truncates to nonsense and can contradict the
            // arrow beside it, which was exactly what happened on a walk (2026-10-17). Long lines go
            // in `detail` instead.
            if let line = Self.directive(lastSpoken) { return line }
            return SpokenText.instruction(kind ?? .continueStraight)
        case .lost: return "Position lost"
        case .obstacleStop: return "Stop"
        case .arrived: return "You have arrived"
        case .failed: return "Guidance can't continue"
        }
    }

    /// The direction the user was actually TOLD, read back out of the spoken line.
    ///
    /// The arrow used to come from `kind`, which updates every tick, while speech is deliberately
    /// rate limited - so the screen could show a left arrow while the voice had just said "Right."
    /// On a debugging screen that is merely confusing; for anyone trusting both it is contradictory
    /// (device report 2026-10-17). The arrow now follows the words.
    public var spokenKind: GuidanceInstruction.Kind? {
        guard let line = lastSpoken?.lowercased(), !line.isEmpty else { return nil }
        if line.hasPrefix("turn around") { return .turnAround }
        if line.contains("left") { return .turnLeft }
        if line.contains("right") { return .turnRight }
        if line.hasPrefix("continue straight") || line.hasPrefix("walk straight") { return .continueStraight }
        return nil
    }

    /// Longest line we are willing to show as a headline before it truncates on a phone.
    static let maxHeadlineCharacters = 30

    /// A short, single instruction ("Right.", "Turn around.") rather than narration. nil when the text
    /// is missing, long, or is a sentence describing several steps.
    static func directive(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        guard text.count <= maxHeadlineCharacters, !text.contains(", then ") else { return nil }
        return text
    }

    /// The line under the headline.
    public var detail: String {
        switch phase {
        case .idle: return ""
        case .localizing: return "Slowly turn left and right"
        case .guiding:
            // Narration that was too long to headline still belongs on screen.
            if let spoken = lastSpoken, !spoken.isEmpty, Self.directive(spoken) == nil { return spoken }
            guard let d = distanceToNext else { return "" }
            return SpokenText.capitalizingFirst(SpokenText.distance(d)) + " to the next point"
        case .lost: return "Hold still"
        case .obstacleStop: return "Obstacle ahead"
        case .arrived: return destinationLabel
        case .failed(let message): return message
        }
    }

    /// One sentence for speech / VoiceOver. Never ends in "..", never empty.
    public var spokenText: String {
        switch phase {
        case .arrived:
            return destinationLabel.isEmpty ? "You have arrived." : "You have arrived at \(destinationLabel)."
        case .guiding:
            var text = headline + "."
            if !detail.isEmpty { text += " \(detail)." }
            if obstacle == .caution { text += " Obstacle ahead." }
            return text
        default:
            return detail.isEmpty ? headline + "." : "\(headline). \(detail)."
        }
    }

    // MARK: Adapter for NavigationController (observe-only)

    /// Parses `NavigationController.instructionText`, which is formatted as
    /// "<GuidanceInstruction.Kind rawValue>, <metres with 1 decimal> m", e.g. "turnRight, 3.0 m".
    public static func parseInstruction(_ text: String) -> (kind: GuidanceInstruction.Kind, distance: Float)? {
        let parts = text.components(separatedBy: ", ")
        guard parts.count == 2, let kind = GuidanceInstruction.Kind(rawValue: parts[0]) else { return nil }
        let number = parts[1].replacingOccurrences(of: " m", with: "")
        guard let distance = Float(number) else { return nil }
        return (kind, distance)
    }

    /// Builds a snapshot from NavigationController's published values.
    public static func derive(
        status: String, instruction: String, obstacle: ObstacleLevel, destinationLabel: String
    ) -> GuidanceSnapshot {
        let parsed = parseInstruction(instruction)
        var s = GuidanceSnapshot(
            kind: parsed?.kind, distanceToNext: parsed?.distance, obstacle: obstacle,
            destinationLabel: destinationLabel, rawStatus: status)

        if status.hasPrefix("No route") {
            s.phase = .failed("There is no route to \(destinationLabel.isEmpty ? "that place" : destinationLabel) in this map.")
        } else if status.hasPrefix("Position lost") || status == "Tracking limited" {
            s.phase = .lost
        } else if status.hasPrefix("Looking for your position") || status.hasPrefix("Opening the saved scan") {
            // Reading the saved scan is part of "finding yourself" from the user's point of view; it
            // just happens before the camera starts. Without this it fell through to .idle and the
            // screen looked stuck (device report 2026-10-17).
            s.phase = .localizing
        } else if status == "Idle" || status == "Stopped" {
            s.phase = .idle
        } else if parsed?.kind == .arrived || status == "Simulation finished" {
            s.phase = .arrived
        } else if obstacle == .stop {
            s.phase = .obstacleStop
        } else if parsed == nil {
            s.phase = .localizing
        } else {
            s.phase = .guiding
        }
        return s
    }
}
