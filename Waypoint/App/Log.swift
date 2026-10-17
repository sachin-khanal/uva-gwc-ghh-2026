//
// File:     Waypoint/App/Log.swift
// Owner:    D (App/Sync/Integration)
// Purpose:  One logger per area (app, capture, reloc, nav, guidance, vision, sync). Each message goes to BOTH:
//             1. the unified system log (`os.Logger`)  -> Console.app, filter: subsystem:io.github.sachin-khanal.waypoint category:capture
//             2. stderr as "[category] LEVEL message"   -> shows up in the terminal under `make launch`, `make selftest-*`
//                                                          (xcrun devicectl ... --console only captures stdout/stderr, NOT the system log).
//           This is what lets a person or an LLM agent watch the app run on a phone from the command line.
// Use:      Log.capture.info("dropped breadcrumb \(count)")  - pass a plain interpolated string. Do not use print().
// Cost:     one fputs per message; log at most a few times per second in hot loops.
//
import Foundation
import os

struct AppLog {
    let category: String
    private let logger: Logger

    init(subsystem: String, category: String) {
        self.category = category
        self.logger = Logger(subsystem: subsystem, category: category)
    }

    func info(_ message: @autoclosure () -> String) {
        let m = message()
        logger.info("\(m, privacy: .public)")
        echo("INFO", m)
    }

    func error(_ message: @autoclosure () -> String) {
        let m = message()
        logger.error("\(m, privacy: .public)")
        echo("ERROR", m)
    }

    private func echo(_ level: String, _ message: String) {
        fputs("[\(category)] \(level) \(message)\n", stderr) // stderr is unbuffered, so lines appear immediately
    }
}

enum Log {
    private static let subsystem = "io.github.sachin-khanal.waypoint"
    static let app = AppLog(subsystem: subsystem, category: "app")
    static let capture = AppLog(subsystem: subsystem, category: "capture")
    static let reloc = AppLog(subsystem: subsystem, category: "reloc")
    static let nav = AppLog(subsystem: subsystem, category: "nav")
    static let guidance = AppLog(subsystem: subsystem, category: "guidance")
    static let vision = AppLog(subsystem: subsystem, category: "vision")
    static let sync = AppLog(subsystem: subsystem, category: "sync")
}
