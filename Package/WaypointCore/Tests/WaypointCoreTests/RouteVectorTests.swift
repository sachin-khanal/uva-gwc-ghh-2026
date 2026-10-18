// File: RouteVectorTests.swift
// Owner: U3 (web parity), B (native router)
// Purpose: Native Router checks against the SAME Samples/route-vectors.json as web tests.
// Frames: Map-frame positions in meters; equal-cost ties deliberately excluded.
// Status: Implemented; pending execution on a Mac. No device claims.
import Foundation
import XCTest
@testable import WaypointCore

final class RouteVectorTests: XCTestCase {
    private struct Vectors: Decodable { let fixtures: [Fixture] }
    private struct Fixture: Decodable {
        let name: String
        let sample: String?
        let map: BuildingMap?
        let cases: [Case]
    }
    private struct Case: Decodable {
        let name: String
        let start: UUID
        let goal: UUID
        let allowStairs: Bool
        let expected: [UUID]?
    }

    func testSharedBrowserRouteVectors() throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        let samples = root.appendingPathComponent("Samples")
        let vectors = try JSONDecoder().decode(Vectors.self,
            from: Data(contentsOf: samples.appendingPathComponent("route-vectors.json")))
        XCTAssertFalse(vectors.fixtures.isEmpty)
        for fixture in vectors.fixtures {
            let map: BuildingMap
            if let inline = fixture.map { map = inline }
            else {
                let filename = try XCTUnwrap(fixture.sample)
                map = try BuildingMap.from(jsonData: Data(contentsOf: samples.appendingPathComponent(filename)))
            }
            try MapBundle(map: map).validate()
            for item in fixture.cases {
                let result = Router.route(in: WaypointGraph(map: map), from: item.start,
                                          to: item.goal, allowStairs: item.allowStairs,
                                          simplify: false) // the browser router returns the raw graph path; the native default thins collinear nodes (RouteSimplifier)
                XCTAssertEqual(result?.map(\.id), item.expected, "\(fixture.name): \(item.name)")
            }
        }
    }
}
