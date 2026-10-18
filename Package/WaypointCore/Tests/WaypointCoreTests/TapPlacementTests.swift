//
// File:     Tests/WaypointCoreTests/TapPlacementTests.swift
// Purpose:  Proves the "tap to place" rule (Flows/TapPlacement): range limit, camera height, and the
//           stand-off that keeps a tapped door/wall point in front of the surface instead of inside it.
//
import XCTest
import simd
@testable import WaypointCore

final class TapPlacementTests: XCTestCase {

    private let camera = SIMD3<Float>(0, 1.4, 0)

    func testDoorAcrossTheHallIsPulledBackToCameraHeight() {
        // A door 4 m ahead, tapped at 1 m above the floor.
        guard case .placeable(let position, let distance) = TapPlacement.evaluate(hit: [0, 1.0, -4], camera: camera) else {
            return XCTFail("expected placeable")
        }
        XCTAssertEqual(position.x, 0, accuracy: 0.001)
        XCTAssertEqual(position.y, 1.4, accuracy: 0.001, "same height as the camera, like a normal tag")
        XCTAssertEqual(position.z, -3.6, accuracy: 0.001, "0.4 m in front of the door")
        XCTAssertEqual(distance, 3.6, accuracy: 0.001)
    }

    func testDiagonalStandOffFollowsTheTapDirection() {
        guard case .placeable(let position, _) = TapPlacement.evaluate(hit: [3, 0, -4], camera: camera) else {
            return XCTFail("expected placeable")
        }
        // 5 m away along (0.6, -0.8): pulled back 0.4 m -> 4.6 m along the same line.
        XCTAssertEqual(position.x, 2.76, accuracy: 0.001)
        XCTAssertEqual(position.z, -3.68, accuracy: 0.001)
    }

    func testTooFarIsRefused() {
        XCTAssertEqual(TapPlacement.evaluate(hit: [0, 0, -7], camera: camera), .tooFar(distance: 7))
        // Height does not count toward the distance: a ceiling point straight above is close.
        guard case .placeable = TapPlacement.evaluate(hit: [0, 3, -1], camera: camera) else {
            return XCTFail("height must not count toward range")
        }
    }

    func testVeryCloseTapIsNotPulledBehindTheVolunteer() {
        guard case .placeable(let position, let distance) = TapPlacement.evaluate(hit: [0, 0, -0.5], camera: camera) else {
            return XCTFail("expected placeable")
        }
        XCTAssertEqual(position.z, -0.5, accuracy: 0.001)
        XCTAssertEqual(distance, 0.5, accuracy: 0.001)
    }

    func testInRangeAfterWalkingOn() {
        let spot = SIMD3<Float>(0, 1.4, -3)
        XCTAssertTrue(TapPlacement.isInRange(spot, camera: camera))
        XCTAssertFalse(TapPlacement.isInRange(spot, camera: [0, 1.4, 4])) // walked 4 m the other way: 7 m
    }
}
