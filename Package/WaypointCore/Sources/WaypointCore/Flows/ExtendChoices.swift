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

    public var areaTitle: String { areaCount > 1 ? "Scan area \(areaNumber) of \(areaCount)" : "Scanned area" }
}

public enum ExtendChoices {
    /// - Parameter hasWorldMap: true when `<map>/worldmap-<segment>.arworldmap` exists on this phone.
    public static func options(maps: [BuildingMap], hasWorldMap: (UUID, String) -> Bool) -> [ExtendOption] {
        maps.sorted { $0.name < $1.name }.flatMap { map -> [ExtendOption] in
            let segments = map.segmentIds
            return segments.enumerated().compactMap { index, segment in
                SegmentID.isValid(segment) && hasWorldMap(map.id, segment)
                    ? ExtendOption(mapId: map.id, mapName: map.name, segmentId: segment, areaNumber: index + 1, areaCount: segments.count)
                    : nil
            }
        }
    }
}
