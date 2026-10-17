//
// File:     Waypoint/App/LaunchCommand.swift
// Owner:    D (App/Sync/Integration) - used by B and A for headless testing
// Purpose:  Self-test switches passed as launch arguments, so the app can be exercised from the command line
//           (no tapping) and report what it did on stderr:
//             -autoSimulate "Room 204"   open Navigator, run the simulated walk to that destination on the sample/first map,
//                                        log every spoken cue / haptic / instruction, print "SELFTEST PASS ..." and exit(0).
//                                        Fails with exit(1) on timeout (120 s) or exit(2) if the map/destination is not found.
//             -autoFacingAway YES        with -autoSimulate: the walker starts facing the wrong way (exercises "turn around").
//             -autoScan YES              open Volunteer mode and start scanning immediately; scan stats (tracking, mapping,
//                                        triangles, box) are logged once per second. Keep walking; stop with Ctrl-C / force quit.
//             -autoE2E YES               run the in-app end-to-end self-test (device capabilities, storage, Keychain, synthetic scan -> save ->
//                                        reload -> share -> simulated walk, optional cloud read) and exit 0/1. See Waypoint/App/E2ESelfTest.swift.
//           Use via:  make selftest-sim   /   make selftest-scan   (see Makefile). The values are read from the process's argument
//           domain with UserDefaults, which is how iOS parses "-key value" arguments.
// Safety:   Only acts when launched with these arguments; a normal launch is unaffected.
//
import Foundation

enum LaunchCommand: Equatable {
    case none
    case simulate(destination: String, facingAway: Bool)
    case scan
    case e2e

    static func fromLaunchArguments(_ defaults: UserDefaults = .standard) -> LaunchCommand {
        if let destination = defaults.string(forKey: "autoSimulate"), !destination.isEmpty {
            return .simulate(destination: destination, facingAway: defaults.bool(forKey: "autoFacingAway"))
        }
        if defaults.bool(forKey: "autoScan") { return .scan }
        if defaults.bool(forKey: "autoE2E") { return .e2e }
        return .none
    }

    var isActive: Bool { self != .none }
}
