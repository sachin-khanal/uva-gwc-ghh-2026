//
// File:     ManualAlignmentTests.swift
// Module:   WaypointCoreTests
// Purpose:  The two-point alignment used to extend a saved map without waiting for ARKit to
//           relocalize. A wrong answer here writes every new node into the wrong part of the
//           building, so the refusals matter as much as the successes.
//
import XCTest
import simd
@testable import WaypointCore

final class ManualAlignmentTests: XCTestCase {

    /// Applies the result to a world point and returns where it lands in the map.
    private func mapped(_ result: Result<simd_float4x4, ManualAlignment.Failure>,
                        _ world: SIMD3<Float>) throws -> SIMD3<Float> {
        guard case .success(let m) = result else {
            XCTFail("expected an alignment, got \(result)")
            throw NSError(domain: "test", code: 1)
        }
        return Geometry.transformPoint(m, world)
    }

    private func assertClose(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ tolerance: Float = 1e-3,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.x, b.x, accuracy: tolerance, file: file, line: line)
        XCTAssertEqual(a.y, b.y, accuracy: tolerance, file: file, line: line)
        XCTAssertEqual(a.z, b.z, accuracy: tolerance, file: file, line: line)
    }

    /// Session frame already equals the map frame: the alignment must change nothing.
    func testAlreadyAlignedIsTheIdentity() throws {
        let a = SIMD3<Float>(1, 0, 1), b = SIMD3<Float>(1, 0, -5)
        let r = ManualAlignment.worldToMap(mapA: a, worldA: a, mapB: b, worldB: b)
        assertClose(try mapped(r, SIMD3(3, 1.4, -2)), SIMD3(3, 1.4, -2))
    }

    /// The session started 10 m away from where the map's origin is, facing the same way.
    func testPureTranslation() throws {
        let offset = SIMD3<Float>(10, 0, -4)
        let mapA = SIMD3<Float>(0, 0, 0), mapB = SIMD3<Float>(0, 0, -6)
        let r = ManualAlignment.worldToMap(mapA: mapA, worldA: mapA + offset,
                                           mapB: mapB, worldB: mapB + offset)
        assertClose(try mapped(r, SIMD3(2, 1.5, -3) + offset), SIMD3(2, 1.5, -3))
    }

    /// The session started facing 90 degrees away from the scan. This is the case a single tapped
    /// place could never solve, and the reason two are required.
    func testQuarterTurn() throws {
        // Map: A at the origin, B six metres along -z. World: the same walk, rotated 90 degrees.
        let mapA = SIMD3<Float>(0, 0, 0), mapB = SIMD3<Float>(0, 0, -6)
        let worldA = SIMD3<Float>(0, 0, 0), worldB = SIMD3<Float>(6, 0, 0)
        let r = ManualAlignment.worldToMap(mapA: mapA, worldA: worldA, mapB: mapB, worldB: worldB)
        // B itself must land on B.
        assertClose(try mapped(r, worldB), mapB, 1e-3)
        // ...and a point to the walker's left stays to their left.
        assertClose(try mapped(r, SIMD3(3, 0, 2)), SIMD3(2, 0, -3), 1e-3)
    }

    /// Height is carried through: the phone sits at eye level in both frames.
    func testHeightIsPreserved() throws {
        let mapA = SIMD3<Float>(0, 1.5, 0), mapB = SIMD3<Float>(0, 1.5, -5)
        let r = ManualAlignment.worldToMap(mapA: mapA, worldA: SIMD3(20, 1.5, 7),
                                           mapB: mapB, worldB: SIMD3(20, 1.5, 2))
        assertClose(try mapped(r, SIMD3(20, 1.5, 7)), mapA)
    }

    // MARK: Refusals - a bad alignment is worse than none

    /// Two places a stride apart cannot fix an angle: a small standing error becomes a large rotation.
    func testRefusesPlacesThatAreTooClose() {
        let r = ManualAlignment.worldToMap(mapA: SIMD3(0, 0, 0), worldA: SIMD3(0, 0, 0),
                                           mapB: SIMD3(0, 0, -1), worldB: SIMD3(0, 0, -1))
        guard case .failure(.tooClose) = r else { return XCTFail("\(r)") }
    }

    /// The map says those two doors are 12 m apart; the volunteer walked 3 m. They tapped the wrong
    /// one, and guessing would scatter the new corridor across the building.
    func testRefusesWhenTheWalkDoesNotMatchTheMap() {
        let r = ManualAlignment.worldToMap(mapA: SIMD3(0, 0, 0), worldA: SIMD3(0, 0, 0),
                                           mapB: SIMD3(0, 0, -12), worldB: SIMD3(0, 0, -3))
        guard case .failure(.lengthMismatch(let mapMeters, let walked)) = r else { return XCTFail("\(r)") }
        XCTAssertEqual(mapMeters, 12, accuracy: 1e-3)
        XCTAssertEqual(walked, 3, accuracy: 1e-3)
    }

    /// Normal standing slop is accepted: nobody stands exactly on a node.
    func testAcceptsRealisticStandingError() throws {
        let mapA = SIMD3<Float>(0, 0, 0), mapB = SIMD3<Float>(0, 0, -8)
        // Walked 8.4 m instead of 8, and drifted 0.3 m sideways.
        let r = ManualAlignment.worldToMap(mapA: mapA, worldA: SIMD3(0, 0, 0),
                                           mapB: mapB, worldB: SIMD3(0.3, 0, -8.4))
        _ = try mapped(r, SIMD3(0, 0, 0)) // must succeed
    }

    func testRefusesNonFiniteInput() {
        let r = ManualAlignment.worldToMap(mapA: SIMD3(0, 0, 0), worldA: SIMD3(.nan, 0, 0),
                                           mapB: SIMD3(0, 0, -6), worldB: SIMD3(0, 0, -6))
        guard case .failure(.notFinite) = r else { return XCTFail("\(r)") }
    }

    /// Round trip on a realistic pair: rotated and translated, every point must land where the map says.
    func testRoundTripOnAnArbitraryPose() throws {
        let theta: Float = 2.1
        let shift = SIMD3<Float>(-7, 0, 13)
        let worldToTruth = Geometry.translationMatrix(shift) * Geometry.rotationY(theta)
        let mapA = SIMD3<Float>(2, 1.4, -3), mapB = SIMD3<Float>(2, 1.4, -11)
        // Build the world points by applying the INVERSE of the pose we expect to recover.
        let truthToWorld = worldToTruth.inverse
        let worldA = Geometry.transformPoint(truthToWorld, mapA)
        let worldB = Geometry.transformPoint(truthToWorld, mapB)

        let r = ManualAlignment.worldToMap(mapA: mapA, worldA: worldA, mapB: mapB, worldB: worldB)
        assertClose(try mapped(r, worldA), mapA, 1e-2)
        assertClose(try mapped(r, worldB), mapB, 1e-2)
        // A third point the solver never saw.
        let mapC = SIMD3<Float>(5, 1.4, -7)
        assertClose(try mapped(r, Geometry.transformPoint(truthToWorld, mapC)), mapC, 1e-2)
    }
}
