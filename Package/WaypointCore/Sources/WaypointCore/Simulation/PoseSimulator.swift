//
// File:     Simulation/PoseSimulator.swift
// Module:   WaypointCore
// Owner:    B (Navigation/Feedback)
// Purpose:  A scripted "virtual walker" that follows a route at walking speed and turns its body
//           toward the direction of travel. Lets B tune spatial audio, haptics and speech with NO scan,
//           NO relocalization and NO LiDAR: the app's Simulate mode feeds these poses into the same
//           navigation loop the real AR frames use.
// Behaviour: moves toward the next route node at `speed` m/s; heading rotates toward the travel
//           direction at `turnRateDegreesPerSecond`, and the walker pauses while it is turning more
//           than `pauseAboveDegrees` (so the "turn right" cue is heard before the walker moves on).
//           This is a test fixture, not a physical model.
//
import Foundation
import simd

public struct PoseSimulator {

    public private(set) var position: SIMD3<Float>
    /// Unit vector on the floor plane.
    public private(set) var forward: SIMD3<Float>
    public private(set) var isFinished = false

    private let waypoints: [SIMD3<Float>]
    private var nextIndex = 1
    private let speed: Float
    private let turnRate: Float
    private let pauseAbove: Float

    /// - Parameters:
    ///   - route: nodes to walk, in order (needs at least 1).
    ///   - startFacing: initial facing; defaults to the direction of the first leg.
    public init(
        route: [MapNode],
        startFacing: SIMD3<Float>? = nil,
        speed: Float = 1.2,
        turnRateDegreesPerSecond: Float = 120,
        pauseAboveDegrees: Float = 20
    ) {
        precondition(!route.isEmpty, "PoseSimulator needs a route")
        self.waypoints = route.map(\.position)
        self.position = route[0].position
        self.speed = speed
        self.turnRate = turnRateDegreesPerSecond * .pi / 180
        self.pauseAbove = pauseAboveDegrees * .pi / 180

        let firstLeg = route.count > 1 ? route[1].position - route[0].position : SIMD3<Float>(0, 0, -1)
        let initial = startFacing ?? firstLeg
        let flat = SIMD3<Float>(initial.x, 0, initial.z)
        self.forward = simd_length(flat) > 1e-5 ? simd_normalize(flat) : SIMD3<Float>(0, 0, -1)
        self.isFinished = route.count == 1
    }

    /// Advances the simulation by `dt` seconds.
    public mutating func step(dt: Float) {
        guard !isFinished, nextIndex < waypoints.count else { isFinished = true; return }

        let target = waypoints[nextIndex]
        var toTarget = target - position
        toTarget.y = 0
        let distance = simd_length(toTarget)
        if distance < 0.05 {
            position = target
            nextIndex += 1
            if nextIndex >= waypoints.count { isFinished = true }
            return
        }
        let desired = toTarget / distance

        // Turn toward the desired heading, limited by the turn rate.
        let error = Geometry.signedBearing(forward: forward, toTarget: desired) // + = desired is to the right
        let maxTurn = turnRate * dt
        let turn = max(-maxTurn, min(maxTurn, error))
        forward = Self.rotate(forward, byClockwise: turn)

        // Only walk when roughly facing the way we are going.
        if abs(error) <= pauseAbove {
            let move = min(distance, speed * dt)
            position += desired * move
        }
    }

    /// Rotates a floor-plane vector so that a positive angle turns RIGHT (same sign as signedBearing).
    static func rotate(_ v: SIMD3<Float>, byClockwise angle: Float) -> SIMD3<Float> {
        // signedBearing is atan2(cross, dot) with cross = fx*dz - fz*dx, so a positive bearing is a
        // rotation of the vector by +angle in the (x, z) plane under (x', z') = (x cos - z sin, x sin + z cos).
        let c = cos(angle), s = sin(angle)
        let r = SIMD3<Float>(v.x * c - v.z * s, 0, v.x * s + v.z * c)
        return simd_normalize(r)
    }
}
