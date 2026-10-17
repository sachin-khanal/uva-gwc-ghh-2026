//
// File:     Model/Keyframe.swift
// Module:   WaypointCore
// Owner:    A (AR/Maps) with C (vision)
// Purpose:  A visual fingerprint of one spot, recorded while scanning, so a returning phone can work
//           out roughly where it is by RECOGNISING the place instead of waiting for ARKit to match
//           feature points.
//
// Why:      ARKit's own relocalization is already image-based, and in a corridor that all looks alike
//           it can take a long time to land ("it takes a while and a bunch of walking around" -
//           device report 2026-10-17). A keyframe adds different information: a whole-image
//           descriptor, compared by nearest neighbour, which recognises a PLACE in one frame.
//
// Honest limits: a descriptor match says "this looks like where the volunteer stood", not an exact
//           pose. Standing a metre to one side, or facing 20 degrees off, still matches. So a keyframe
//           gives a COARSE fix to start guidance from, and ARKit's own relocalization refines it when
//           it lands. `Relocalizer` marks the difference so the UI can say which one it has.
//
// Privacy: we store a DESCRIPTOR, never the photograph. It cannot be turned back into the image, which
//           matters because these are taken inside buildings full of people, and maps are shared.
//
// Status:   DONE (pure logic, unit-tested). The descriptor itself is produced on the app side by
//           Vision; this file never imports it, so the maths stays testable on a Mac.
//
import Foundation
import simd

public struct Keyframe: Codable, Equatable, Sendable {

    public var id: UUID
    /// Where the camera was, MAP frame, metres.
    public var position: SIMD3<Float>
    /// Which way it faced about the vertical axis, radians (0 = -z, positive toward +x).
    public var yaw: Float
    /// Opaque descriptor bytes (an Apple Vision feature print). Compared only by the distance
    /// function the caller supplies, so this module needs no knowledge of the format.
    public var descriptor: Data

    public init(id: UUID = UUID(), position: SIMD3<Float>, yaw: Float, descriptor: Data) {
        self.id = id
        self.position = position
        self.yaw = yaw
        self.descriptor = descriptor
    }

    /// Camera pose in the MAP frame, in the same form the marker path uses.
    public var poseInMap: simd_float4x4 {
        Geometry.translationMatrix(position) * Geometry.rotationY(yaw)
    }

    /// Given where the camera is NOW in world coordinates, the transform taking map points to world
    /// points. Same derivation as `MarkerRef.mapToWorldTransform`: we assume the user is standing
    /// roughly where this keyframe was taken, which is what the descriptor match asserts.
    public func mapToWorldTransform(cameraWorld: simd_float4x4) -> simd_float4x4 {
        cameraWorld * poseInMap.inverse
    }
}

/// The keyframes of one map, and the rule for picking a match.
public struct KeyframeIndex: Equatable, Sendable {

    /// A match further away than this is not trusted. Vision's feature-print distances are not
    /// normalised, so this is a starting point to tune on a phone, not a derived constant.
    public static let defaultMaxDistance: Float = 18

    /// How much better the best match must be than the runner-up, as a fraction. A corridor photographs
    /// much the same from several places; if two spots match nearly equally we cannot tell them apart
    /// and must not guess, because a confident wrong fix is worse than no fix.
    public static let defaultAmbiguityRatio: Float = 0.8

    public var keyframes: [Keyframe]

    public init(keyframes: [Keyframe] = []) {
        self.keyframes = keyframes
    }

    public struct Match: Equatable {
        public var keyframe: Keyframe
        public var distance: Float
        /// Distance to the next-best keyframe that is not a near neighbour of the winner, if any.
        public var runnerUpDistance: Float?
    }

    /// Nearest keyframe to `descriptor`, or nil when nothing is close enough or the answer is
    /// ambiguous.
    ///
    /// - Parameter distance: supplied by the caller (Vision computes it); must be >= 0, smaller =
    ///   more similar.
    /// - Parameter minSeparation: two keyframes closer together than this in SPACE are the same place
    ///   for ambiguity purposes, so one does not disqualify the other.
    public func best(
        matching descriptor: Data,
        maxDistance: Float = defaultMaxDistance,
        ambiguityRatio: Float = defaultAmbiguityRatio,
        minSeparation: Float = 3,
        distance: (Data, Data) -> Float?
    ) -> Match? {
        var scored: [(frame: Keyframe, d: Float)] = []
        for frame in keyframes {
            guard let d = distance(descriptor, frame.descriptor), d.isFinite else { continue }
            scored.append((frame, d))
        }
        guard let winner = scored.min(by: { $0.d < $1.d }), winner.d <= maxDistance else { return nil }

        // The runner-up only counts if it is somewhere ELSE; neighbouring keyframes of the same spot
        // naturally score alike and should not make the answer look ambiguous.
        let runnerUp = scored
            .filter { Geometry.horizontalDistance($0.frame.position, winner.frame.position) > minSeparation }
            .min(by: { $0.d < $1.d })

        if let runnerUp, winner.d > runnerUp.d * ambiguityRatio {
            return nil // two different places look equally like this one
        }
        return Match(keyframe: winner.frame, distance: winner.d, runnerUpDistance: runnerUp?.d)
    }

    /// True when `position` is far enough from every stored keyframe to be worth recording.
    /// Keeps the map from filling with near-identical frames while the volunteer stands still.
    public func shouldRecord(at position: SIMD3<Float>, spacing: Float) -> Bool {
        !keyframes.contains { Geometry.horizontalDistance($0.position, position) < spacing }
    }
}
