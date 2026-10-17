//
// File:     Waypoint/App/Log.swift
// Owner:    D (App/Sync/Integration)
// Purpose:  One `os.Logger` per area so `make run` (which streams the phone's console) and
//           Console.app can be filtered by area. Use these instead of print().
//           Example:  Log.capture.info("dropped breadcrumb \(count)")
// Filter:   make logs   (or Console.app -> subsystem:io.github.sachin-khanal.waypoint category:capture)
//
import os

enum Log {
    private static let subsystem = "io.github.sachin-khanal.waypoint"
    static let app = Logger(subsystem: subsystem, category: "app")
    static let capture = Logger(subsystem: subsystem, category: "capture")
    static let reloc = Logger(subsystem: subsystem, category: "reloc")
    static let nav = Logger(subsystem: subsystem, category: "nav")
    static let guidance = Logger(subsystem: subsystem, category: "guidance")
    static let vision = Logger(subsystem: subsystem, category: "vision")
    static let sync = Logger(subsystem: subsystem, category: "sync")
}
