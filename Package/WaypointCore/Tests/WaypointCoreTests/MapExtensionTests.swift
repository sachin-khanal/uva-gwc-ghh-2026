// File: MapExtensionTests.swift
// Owner: A / U3 (requested extension integration)
// Purpose: Check map identity, attachment bounds, and compatibility with local imports.
// Frames: All synthetic positions are map-frame meters. No AR/device assertions.
// Status: Implemented; execution requires a Mac with the Swift package toolchain.
import XCTest
@testable import WaypointCore

final class MapExtensionTests: XCTestCase {
    func testExtensionPreservesBuildingAndLinksNewSegment() throws {
        let original = try loadSampleMap()
        let builder = MapBuilder(map: original, segmentId: "extension_1", deviceName: "second")
        XCTAssertTrue(builder.attachExtension(at: [0, 0, -3.1]))
        _ = builder.observe(position: [0, 0, -5])
        let extended = builder.map
        XCTAssertEqual(extended.id, original.id)
        XCTAssertEqual(extended.name, original.name)
        XCTAssertEqual(Array(extended.nodes.prefix(original.nodes.count)), original.nodes)
        XCTAssertEqual(Array(extended.edges.prefix(original.edges.count)), original.edges)
        XCTAssertEqual(extended.version, original.version + 1)
        let first = extended.nodes[original.nodes.count]
        XCTAssertEqual(first.segmentId, "extension_1")
        XCTAssertTrue(extended.edges.contains { $0.connects(original.nodes[1].id, first.id) })
        XCTAssertNotNil(Router.route(in: WaypointGraph(map: extended), from: original.nodes[0].id,
                                    to: extended.nodes.last!.id))
        try MapBundle(map: extended).validate()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = MapStore(rootURL: folder)
        try store.save(original)
        let imported = try store.importBundle(MapBundle(map: extended))
        XCTAssertEqual(imported.nodes.count, extended.nodes.count)
        XCTAssertEqual(imported.edges.count, extended.edges.count)
    }

    func testExtensionRejectsUnsafeAttachmentWithoutMutatingMap() throws {
        let original = try loadSampleMap()
        let invalidPositions: [SIMD3<Float>] = [[100, 0, 100], [0, 3, 0], [0, 0, -15], [.nan, 0, 0]]
        for position in invalidPositions {
            let builder = MapBuilder(map: original, segmentId: "new_segment", deviceName: "test")
            XCTAssertFalse(builder.attachExtension(at: position))
            XCTAssertEqual(builder.map, original)
        }
        for segment in ["seg1", "../bad"] {
            let builder = MapBuilder(map: original, segmentId: segment, deviceName: "test")
            XCTAssertFalse(builder.attachExtension(at: [0, 0, 0]))
            XCTAssertEqual(builder.map, original)
        }
    }

    func testAttachmentOnlyHappensOnce() throws {
        let builder = MapBuilder(map: try loadSampleMap(), segmentId: "new", deviceName: "test")
        XCTAssertTrue(builder.attachExtension(at: [0, 0, 0]))
        let attached = builder.map
        XCTAssertFalse(builder.attachExtension(at: [0, 0, 0]))
        XCTAssertEqual(builder.map, attached)
    }
}
