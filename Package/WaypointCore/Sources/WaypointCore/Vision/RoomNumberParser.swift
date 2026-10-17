//
// File:     Vision/RoomNumberParser.swift
// Module:   WaypointCore
// Owner:    C (Vision)
// Purpose:  Turns raw OCR strings into trustworthy room numbers.
//           * `RoomNumberParser.extract` : finds things that look like room numbers in text.
//           * `ConsensusFilter`          : only confirms a number after it has been read N times,
//                                          so one-frame OCR misreads never reach the user or map.
// Input:    strings from Waypoint/Vision/SignReader.swift (Apple Vision text recognition).
// Pattern:  3 digits with an optional trailing letter ("204", "112B"). Rice Hall conventions may
//           need more patterns (e.g. "R-204"); add them HERE with a test in VisionLogicTests.
//
import Foundation

public enum RoomNumberParser {

    private static let pattern = try! NSRegularExpression(pattern: #"\b\d{3}[A-Z]?\b"#)

    /// All room-number-looking tokens in the given OCR lines, uppercased, de-duplicated, in order found.
    public static func extract(from lines: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for line in lines {
            let text = line.uppercased()
            let range = NSRange(text.startIndex..., in: text)
            for match in pattern.matches(in: text, range: range) {
                if let r = Range(match.range, in: text) {
                    let token = String(text[r])
                    if seen.insert(token).inserted { result.append(token) }
                }
            }
        }
        return result
    }
}

/// Confirms a value after it has been observed `requiredReads` times (not necessarily consecutive).
public struct ConsensusFilter {

    public let requiredReads: Int
    private var counts: [String: Int] = [:]
    private var confirmed: Set<String> = []

    public init(requiredReads: Int = 3) {
        self.requiredReads = max(1, requiredReads)
    }

    /// Feed the candidates seen in ONE frame. Returns the values that became confirmed on this call.
    public mutating func ingest(_ candidates: [String]) -> [String] {
        var newlyConfirmed: [String] = []
        for c in candidates {
            counts[c, default: 0] += 1
            if counts[c, default: 0] >= requiredReads, confirmed.insert(c).inserted {
                newlyConfirmed.append(c)
            }
        }
        return newlyConfirmed
    }

    public mutating func reset() {
        counts.removeAll()
        confirmed.removeAll()
    }
}
