//
// File:     Tests/WaypointCoreTests/MapSchemaTests.swift
// Purpose:  Map FORMAT versioning (docs/MAP_FORMAT.md): every historical format still decodes and is migrated,
//           the current format is written, and a newer format is refused with a clear message.
//
import XCTest
@testable import WaypointCore

final class MapSchemaTests: XCTestCase {

    private func fixture(_ name: String, file: StaticString = #filePath) throws -> Data {
        var url = URL(fileURLWithPath: "\(file)")
        for _ in 0..<5 { url.deleteLastPathComponent() } // repo root
        return try Data(contentsOf: url.appendingPathComponent("docs/map-format/\(name)"))
    }

    func testFormat1FixtureHasNoSchemaKeyAndMigratesToCurrent() throws {
        let data = try fixture("map-v1.json")
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("schemaVersion"))
        let map = try BuildingMap.from(jsonData: data)
        XCTAssertEqual(map.schemaVersion, MapSchema.current)
        XCTAssertEqual(map.nodes.count, 9)
    }

    func testFormat2FixtureDecodes() throws {
        let map = try BuildingMap.from(jsonData: try fixture("map-v2.json"))
        XCTAssertEqual(map.schemaVersion, MapSchema.current) // migrated in memory
        XCTAssertEqual(map.edges.count, 8)
        XCTAssertTrue(map.nodes.allSatisfy { $0.extent == nil })
    }

    func testFormat3FixtureCarriesRoomExtent() throws {
        let map = try BuildingMap.from(jsonData: try fixture("map-v3.json"))
        XCTAssertEqual(map.schemaVersion, 3)
        XCTAssertEqual(map.nodes.compactMap(\.extent).count, 1)
        XCTAssertEqual(try BuildingMap.from(jsonData: map.jsonData()), map) // extent round-trips
    }

    func testV1AndV2FixturesDecodeToTheSameMap() throws {
        XCTAssertEqual(try BuildingMap.from(jsonData: try fixture("map-v1.json")),
                       try BuildingMap.from(jsonData: try fixture("map-v2.json")))
    }

    func testSavingAlwaysWritesCurrentFormat() throws {
        let json = String(decoding: try BuildingMap(name: "x").jsonData(), as: UTF8.self)
        XCTAssertTrue(json.contains("\"schemaVersion\" : \(MapSchema.current)"), json)
        // legacy in -> current out
        let resaved = String(decoding: try BuildingMap.from(jsonData: try fixture("map-v1.json")).jsonData(), as: UTF8.self)
        XCTAssertTrue(resaved.contains("\"schemaVersion\" : \(MapSchema.current)"))
    }

    func testNewerFormatIsRefusedWithClearMessage() throws {
        let text = String(decoding: try fixture("map-v2.json"), as: UTF8.self)
            .replacingOccurrences(of: "\"schemaVersion\": 2", with: "\"schemaVersion\": \(MapSchema.current + 1)")
        XCTAssertThrowsError(try BuildingMap.from(jsonData: Data(text.utf8))) { error in
            XCTAssertTrue("\(error)".contains("newer than this app understands"), "\(error)")
        }
    }

    func testNonsenseFormatNumbersAreRefused() throws {
        for bad in ["0", "-3"] {
            let text = String(decoding: try fixture("map-v2.json"), as: UTF8.self)
                .replacingOccurrences(of: "\"schemaVersion\": 2", with: "\"schemaVersion\": \(bad)")
            XCTAssertThrowsError(try BuildingMap.from(jsonData: Data(text.utf8)), bad)
        }
    }

    func testBundleRoundTripKeepsFormatAndRefusesNewer() throws {
        let bundle = MapBundle(map: try BuildingMap.from(jsonData: try fixture("map-v1.json")))
        let back = try JSONDecoder().decode(MapBundle.self, from: JSONEncoder().encode(bundle))
        XCTAssertEqual(back.map.schemaVersion, MapSchema.current)
        try back.validate()
        var json = try XCTUnwrap(String(data: JSONEncoder().encode(bundle), encoding: .utf8))
        json = json.replacingOccurrences(of: "\"schemaVersion\":\(MapSchema.current)", with: "\"schemaVersion\":99")
        XCTAssertThrowsError(try JSONDecoder().decode(MapBundle.self, from: Data(json.utf8)))
    }

    func testMigrateStepsToCurrent() {
        XCTAssertEqual(MapSchema.migrate(from: 1), MapSchema.current)
        XCTAssertEqual(MapSchema.migrate(from: MapSchema.current), MapSchema.current)
    }
}
