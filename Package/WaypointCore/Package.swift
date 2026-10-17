// swift-tools-version: 5.9
//
// File:     Package/WaypointCore/Package.swift
// Purpose:  Swift package holding ALL pure-logic code (no ARKit / UIKit / AVFoundation):
//           data model, map storage, graph routing, guidance planning, vision math.
// Why:      The Simulator runtime is not installed on our Macs and LiDAR/ARKit only works on a
//           physical phone, so anything that can be tested WITHOUT a phone lives here and is
//           tested with `make test` (which runs `swift test` on macOS in about a second).
// Used by:  The iOS app target (see /project.yml -> packages -> WaypointCore).
// Rule:     Do NOT import ARKit, UIKit, AVFoundation, Vision or MultipeerConnectivity in this
//           package. Platform glue belongs in /Waypoint. See /AGENTS.md "Where does code go?".
//
import PackageDescription

let package = Package(
    name: "WaypointCore",
    // macOS is listed ONLY so `swift test` can run on the dev Macs. The shipped app is iOS 17+.
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "WaypointCore", targets: ["WaypointCore"]),
    ],
    targets: [
        .target(name: "WaypointCore"),
        .testTarget(name: "WaypointCoreTests", dependencies: ["WaypointCore"]),
    ]
)
