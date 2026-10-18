//
// File:     Flows/ExtendChoices.swift
// Module:   WaypointCore
// Owner:    U3 (UI flows) with U1 (capture)
// Purpose:  Which saved scan areas can be EXTENDED from the new Scanner's "Extend a map" button. Extending relocalizes in a saved
//           ARWorldMap first, so a segment is only offered if its world map file exists on THIS phone (the sample map and maps downloaded
//           without their scan files are not). Pure so it is unit-tested (the file check is passed in).
// Status:   DONE (logic, unit tested).
//
import Foundation

public struct ExtendOption: Equatable, Identifiable, Sendable {
    public var mapId: UUID
    public var mapName: String
    public var segmentId: String
    /// 1-based position of the segment in the map, for "Scan area 2".
    public var areaNumber: Int
    public var areaCount: Int
    public var id: String { "\(mapId.uuidString)/\(segmentId)" }

    /// Breadcrumbs recorded in this area. A bigger area is easier for ARKit to recognise.
    public var pointCount: Int = 0
    /// Labelled places inside this area, so the volunteer can tell WHERE it is. "Scan area 2 of 2" told
    /// them nothing, and picking the wrong one asks ARKit to recognise a part of the building they are
    /// not standing in - which never succeeds, however long they wait (device report 2026-10-18).
    public var placeNames: [String] = []

    public var areaTitle: String { areaCount > 1 ? "Scan area \(areaNumber) of \(areaCount)" : "Scanned area" }

    /// What the area actually contains: the places in it, or failing that its size.
    public var whereItIs: String {
        placeNames.isEmpty ? "\(pointCount) points, nothing labelled" : placeNames.joined(separator: ", ")
    }

    /// The first area is the original scan; later ones were added by extending it.
    public var isOriginal: Bool { areaNumber == 1 }
}

public enum ExtendChoices {
    /// - Parameter hasWorldMap: true when `<map>/worldmap-<segment>.arworldmap` exists on this phone.
    public static func options(maps: [BuildingMap], hasWorldMap: (UUID, String) -> Bool) -> [ExtendOption] {
        maps.sorted { $0.name < $1.name }.flatMap { map -> [ExtendOption] in
            let segments = map.segmentIds
            return segments.enumerated().compactMap { index, segment -> ExtendOption? in
                guard SegmentID.isValid(segment), hasWorldMap(map.id, segment) else { return nil }
                let inSegment = map.nodes.filter { $0.segmentId == segment }
                return ExtendOption(
                    mapId: map.id, mapName: map.name, segmentId: segment,
                    areaNumber: index + 1, areaCount: segments.count,
                    pointCount: inSegment.count,
                    placeNames: inSegment
                        .compactMap { $0.label?.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                        .sorted())
            }
        }
    }
}
