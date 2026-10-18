//
// File:     FloorAheadTests.swift
// Module:   WaypointCoreTests
// Purpose:  Descending stairs and ledges. Everything else in the app looks for things that stick UP,
//           so a staircase going down reads as clear corridor - the most dangerous miss there is.
//           These tests care most about the cases where we must NOT say "clear".
//
import XCTest
@testable import WaypointCore

final class FloorAheadTests: XCTestCase {

    /// Flat corridor: floor seen all the way out, at the height the user is standing on.
    func testFlatFloorIsContinuous() {
        let samples = (1...10).map { FloorSample(ahead: Float($0) * 0.25, y: 0) }
        XCTAssertEqual(FloorAhead.verdict(samples: samples, standingFloorY: 0), .continuous)
    }

    /// A whole flight going down, a metre and a half ahead.
    func testStaircaseGoingDownIsADrop() {
        var samples = (1...5).map { FloorSample(ahead: Float($0) * 0.3, y: 0) } // floor up to 1.5 m
        // Treads falling away beyond the edge.
        samples += [FloorSample(ahead: 1.6, y: -0.17), FloorSample(ahead: 1.8, y: -0.34),
                    FloorSample(ahead: 2.0, y: -0.51), FloorSample(ahead: 2.2, y: -0.68)]
        guard case .drop(let at, let by) = FloorAhead.verdict(samples: samples, standingFloorY: 0) else {
            return XCTFail("a staircase must not read as floor")
        }
        XCTAssertEqual(at, 1.6, accuracy: 0.01)
        XCTAssertGreaterThanOrEqual(by, FloorAhead.stairsDropMeters, "a flight, not a kerb")
        XCTAssertEqual(FloorAhead.speech(for: .drop(atMeters: at, byMeters: by)),
                       "Stop. Stairs going down about 2 steps ahead.")
    }

    /// A single step down is worth a caution, not a stop.
    func testASingleStepDownIsACaution() {
        var samples = (1...4).map { FloorSample(ahead: Float($0) * 0.25, y: 0) }
        samples += [FloorSample(ahead: 1.2, y: -0.18), FloorSample(ahead: 1.5, y: -0.18)]
        guard case .drop(let at, let by) = FloorAhead.verdict(samples: samples, standingFloorY: 0) else {
            return XCTFail("a step down is still a drop")
        }
        XCTAssertLessThan(by, FloorAhead.stairsDropMeters)
        XCTAssertEqual(FloorAhead.speech(for: .drop(atMeters: at, byMeters: by))?.hasPrefix("Careful."), true)
    }

    /// THE DANGEROUS CASE. From the top of a staircase the treads are edge-on and return almost
    /// nothing, so the floor simply stops coming back. That must never read as clear.
    func testFloorThatVanishesIsNotClear() {
        // Floor only out to 0.6 m, then nothing at all.
        let samples = [FloorSample(ahead: 0.3, y: 0), FloorSample(ahead: 0.6, y: 0)]
        XCTAssertEqual(FloorAhead.verdict(samples: samples, standingFloorY: 0), .unsure,
                       "no floor seen ahead is not the same as floor ahead")
    }

    /// Nothing at all from the sensor is also not clear.
    func testNoSamplesIsUnsure() {
        XCTAssertEqual(FloorAhead.verdict(samples: [], standingFloorY: 0), .unsure)
    }

    /// Carpet, thresholds and depth noise must not keep announcing a step down.
    func testSmallHeightNoiseIsStillContinuous() {
        let samples = (1...10).map { FloorSample(ahead: Float($0) * 0.25, y: ($0 % 2 == 0) ? -0.03 : 0.02) }
        XCTAssertEqual(FloorAhead.verdict(samples: samples, standingFloorY: 0), .continuous)
    }

    /// A ramp down is gradual: no single sample is a step, so it is not reported as one.
    func testAGentleRampIsNotADrop() {
        let samples = (1...10).map { FloorSample(ahead: Float($0) * 0.25, y: -Float($0) * 0.01) }
        XCTAssertEqual(FloorAhead.verdict(samples: samples, standingFloorY: 0), .continuous)
    }

    /// Going UP is not a drop - the stairs-ahead warning for that comes from the obstacle band.
    func testStepsGoingUpAreNotADrop() {
        var samples = (1...4).map { FloorSample(ahead: Float($0) * 0.25, y: 0) }
        samples += [FloorSample(ahead: 1.2, y: 0.17), FloorSample(ahead: 1.4, y: 0.34)]
        XCTAssertEqual(FloorAhead.verdict(samples: samples, standingFloorY: 0), .continuous)
    }

    /// Only the look-ahead matters: a drop at the far end of a hall is not yet news.
    func testADropBeyondTheLookaheadIsIgnored() {
        var samples = (1...8).map { FloorSample(ahead: Float($0) * 0.25, y: 0) }
        samples += [FloorSample(ahead: 6, y: -1.5)]
        XCTAssertEqual(FloorAhead.verdict(samples: samples, standingFloorY: 0), .continuous)
    }

    /// The nearest edge is the one the user meets, even when deeper samples arrive first in the array.
    func testTheNearestEdgeIsReported() {
        let samples = [FloorSample(ahead: 2.2, y: -0.9), FloorSample(ahead: 0.3, y: 0),
                       FloorSample(ahead: 1.4, y: -0.2), FloorSample(ahead: 1.0, y: 0)]
        guard case .drop(let at, _) = FloorAhead.verdict(samples: samples, standingFloorY: 0) else {
            return XCTFail("expected a drop")
        }
        XCTAssertEqual(at, 1.4, accuracy: 0.01)
    }

    func testNonFiniteInputIsUnsure() {
        XCTAssertEqual(FloorAhead.verdict(samples: [FloorSample(ahead: 1, y: 0)], standingFloorY: .nan),
                       .unsure)
    }

    func testContinuousAndUnsureSayNothing() {
        XCTAssertNil(FloorAhead.speech(for: .continuous))
        XCTAssertNil(FloorAhead.speech(for: .unsure))
    }
}
