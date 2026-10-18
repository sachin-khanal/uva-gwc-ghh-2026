# Map file format — specification per version

Added 2026-10-17 (Claude, CONTRACT CHANGE). Source of truth in code: `Model/MapTypes.swift`, `Model/BuildingMap.swift`
(`MapSchema`), `Model/MapStore.swift` (`MapBundle.validate`). Checkers: `tools/validate_map.py`, `supabase/migrations/`.
Example file per version: `docs/map-format/map-v1.json`, `docs/map-format/map-v2.json`.

## Two different version numbers (do not confuse)

| Field | Meaning | Changes when |
|---|---|---|
| `schemaVersion` | **Format** of the JSON (this document) | the SHAPE of the file changes (rare, announced as CONTRACT CHANGE) |
| `version` | **Content revision** of one building's map | someone extends/saves/merges the map (sync uses it to see who is newer) |

## Rules that apply to every version

- Units: metres. Frame: the ARKit world frame of the scan session (+x right, +y up, −z forward). `SIMD3<Float>` is a 3-element array `[x, y, z]`.
- Unknown extra keys are ignored on read (Swift `Codable`), so a NEWER file with only added optional keys is still readable by an older app.
- Files are written with sorted keys, pretty-printed (stable git diffs).
- **Reading:** a missing `schemaVersion` means format 1. Any format from 1 to the app's current one is accepted and **migrated in memory** to the current format; saving writes the current format. A format **newer** than the app understands is **refused** with "…newer than this app understands. Update Waypoint." (never half-read).
- **Writing:** always the app's current format.
- The server (`canonical_buildings.map_json`) stores whatever JSON it is given; readers migrate on load, so rows written before format 2 stay valid.
- Limits (all versions): ≤ 5 000 nodes, ≤ 20 000 edges, ≤ 50 MB per world map, segment ids `[A-Za-z0-9_-]{1,64}`, finite positions, unique node ids, every edge joins two existing different nodes, edge `distance` within max(0.5 m, 25 %) of the straight-line distance of its nodes.

## Format 3 (current)

**Update 2026-10-17 (Claude):** format 3 = format 2 plus the OPTIONAL per-node key `extent` (room floor area derived from the scan mesh, added on branch `navigation-overhaul`):
`"extent": { "center": [x,y,z], "halfExtents": [halfWidthX, halfDepthZ], "yaw": radians, "areaSquareMeters": float }` (`y` of `center` is floor level). Maps without `extent` stay valid; guidance then falls back to a fixed arrival radius.
**Update 2026-10-18 (Claude, integration of U2's `navigation-overhaul`):** format 3 ALSO includes the optional map-level list `keyframes` (U2's visual fingerprints for faster relocalization: `Model/Keyframe.swift`; absent or empty = none; older maps decode with none; limits `MapBundle.maxKeyframes` = 5000 and `maxKeyframeDescriptorBytes` = 64 KB, finite poses, enforced in `MapBundle.validate()`). `tools/validate_map.py`, `web/router.js` and migration 0005 do NOT yet check `keyframes` (they ignore the key; U3/U1 to add the same limits).
**Update 2026-10-18 (Claude):** format 3 ALSO includes (both optional, shared with U3's web viewer): `extent.heightMeters` (ceiling height, metres, 0 < h <= 20) and the map-level list `meshAssets` (3D surface files): `[{ "id": UUID, "segmentId": "seg1" (must exist in the map), "format": "obj", "coordinateFrame": "map", "byteCount": 1...40000000, "sha256": 64 lowercase hex, "boundsMin": [x,y,z], "boundsMax": [x,y,z] (min <= max), "storageOwner": UUID or absent }]`, at most 100 files and 80 MB in total. The app does not CREATE `meshAssets` yet but keeps them when it loads, saves and merges a map. Validation on import (`MapBundle.validate()`), in `tools/validate_map.py`, in `web/router.js` and on the server (`supabase/migrations/0005_map_extras_constraint.sql`): extents belong to rooms only, finite numbers, half sizes in (0.05, 30] m, area > 0 and <= 4*hx*hz, and the room's own place lies in or next to the rectangle (so a hostile map cannot make "You have arrived" fire elsewhere). Example: `docs/map-format/map-v3.json`. Example: `docs/map-format/map-v3.json`. `schemaVersion` must be 1...3. Older apps ignore `extent`.

## ~~Format 2 (current)~~ Format 2 (readable; was current until format 3)

```json
{
  "schemaVersion": 2,
  "id": "UUID",
  "name": "Rice Hall, floor 1",
  "version": 1,
  "marker": { "name": "...", "widthMeters": 0.2, "position": [0, 1.2, 0.1], "yaw": 0 },
  "nodes": [ { "id": "UUID", "kind": "room", "label": "Room 204", "position": [1.5, 0, -9], "segmentId": "seg1", "createdBy": "iPhone-ab12" } ],
  "edges": [ { "from": "UUID", "to": "UUID", "distance": 3.0, "hazard": "stairs" } ]
}
```

| Key | Type | Required | Notes |
|---|---|---|---|
| `schemaVersion` | integer | yes on write; optional on read (missing = 1) | must be ≥ 1 and ≤ the app's current format (3). ~~(2)~~ |
| `id` | UUID string | yes | identity of the building; one UUID = one shared building |
| `name` | string | yes | display name |
| `version` | integer | yes | content revision, starts at 1 |
| `marker` | object | no | fallback relocalization image: `name` string, `widthMeters` float, `position` [x,y,z], `yaw` float (radians) |
| `nodes[]` | array | yes | see below |
| `edges[]` | array | yes | undirected walkable connections |

`nodes[]`: `id` UUID, `kind` one of `corridor | door | stairs | elevator | room | junction`, `label` string (optional; destinations carry one), `position` [x,y,z], `segmentId` safe string, `createdBy` string.
`edges[]`: `from` UUID, `to` UUID, `distance` float metres, `hazard` optional one of `stairs | narrow | doorThreshold`.

### Bundle (`.waypointmap`, AirDrop / cloud download)
`{ "map": <map as above>, "worldMaps": { "<segmentId>": "<base64 ARWorldMap>" } }`. `worldMaps` may be empty. The bundle itself has no version; the embedded `map.schemaVersion` governs.

### On-disk layout
`<Documents>/Maps/<map-uuid>/map.json` and `worldmap-<segmentId>.arworldmap`.
**Update 2026-10-17 (Claude):** the folder can also hold `route-memory.json` (derived cache, never shared) and `model.usdz` (3D model of the scan, written when a scan is saved; not part of `.waypointmap` bundles or cloud sync yet). Neither changes the map format.

## Format 1 (legacy, still readable)

Identical to format 2 **except there is no `schemaVersion` key**. All files written before 2026-10-17 are format 1, including `Samples/rice-hall-sample.json` at that time. Migration 1 → 2: none needed beyond setting `schemaVersion = 2` on load.

## How to add format N+1 (checklist)

1. Add a section above for the new format and a fixture `docs/map-format/map-vN+1.json`.
2. Swift: bump `MapSchema.current`, add the conversion in `MapSchema.migrate`, keep decoding every older fixture (`MapSchemaTests`).
3. Python: bump `CURRENT_SCHEMA` in `tools/validate_map.py` and add a test.
4. SQL: if the server must reject/convert the new shape, add a new migration (never edit applied ones).
5. Tag the WORKLOG entry `CONTRACT CHANGE`, update `Samples/rice-hall-sample.json`, MODULES.md and TESTING.md.

## Known limits

The Swift, Python and SQL checks are three separate implementations of the same rules; `MapSchemaTests` and `tools/test_validate_map.py` both run the same two fixtures, which is what keeps them aligned.

## ~~Known alignment issue: two meanings of "format 3"~~ RESOLVED 2026-10-18: one format 3 (found when merging U3's web viewer)

**Update 2026-10-18 (Claude):** resolved. The app now carries and validates `meshAssets` and `extent.heightMeters` exactly like the web viewer (see Format 3 above); a map written by either side loads in the other and survives a load/save in the app. What follows is the original problem statement, kept for the record.

**Update 2026-10-18 (Claude):** U3's web viewer (`web/`, merged to main) also calls its extended map "schema 3": it accepts `schemaVersion` 1 to 3 and, from 3 on, validates OPTIONAL `meshAssets` (a list of OBJ surface files: id, segmentId, format "obj", coordinateFrame "map", byteCount, sha256, bounds) and room/mesh fields. The native app's format 3 (this document) adds only the optional `MapNode.extent`. Both are optional additions, so every file written today loads in both; but they are not the same list of fields.
- ~~The native `BuildingMap` does not know `meshAssets`: loading a map that has it and saving it again would DROP it (Codable ignores unknown keys).~~ **Update 2026-10-18 (Claude):** it knows it now (`BuildingMap.meshAssets`, `MeshAsset`), test `testMeshAssetsSurviveAnAppLoadAndSave`. Nothing in the app writes `meshAssets` yet.
- Needs a decision by U1 (contract owner) and U3 before any code writes `meshAssets`: either the native model gains an optional `meshAssets` (round-trips it), or the web viewer's extra fields move to format 4. Until then do not publish maps with `meshAssets` from anything that re-saves through the app.
- ~~The native 3D model is `model.usdz` next to `map.json` (not listed in the map JSON); the web viewer reads OBJ. A USDZ-to-OBJ export is not built.~~
  **Update 2026-10-18 (Claude, branch `feature/web-mesh-obj`):** the app now ALSO writes a web copy of the scan as `mesh-<asset id>.obj` next to `map.json` and lists it in `meshAssets` (`ObjExport`, `MapStore.attachMesh`); `SyncEngine.push` uploads it to `meshes/<owner>/<map>/<asset>.obj` and lists it on the server with `publish_mesh_assets` (migration ~~0007~~ **Update 2026-10-18 (Claude):** 0008 (renamed: a different 0007 exists on the live project), not yet applied). `model.usdz` stays the phone's own viewer format. UNVERIFIED ON DEVICE.

**Update 2026-10-18 (Claude): versioning check on real data.** Behaviour is as designed: `schemaVersion` is the FORMAT of the file, stamped with the app's current format (3) whenever a map is saved; it does NOT say how rich one map is. Evidence: all 5 scans on Sachin's phone (made on different days, the oldest before OBJ export existed) and all 8 live cloud rows say `schemaVersion` 3; formats 1, 2 and 3 fixtures, the bundled-style sample and every real map pass `tools/validate_map.py`; `MapSchemaTests` 9/9. Richness is carried by the OPTIONAL fields instead: `meshAssets` (2 of 5 scans: the two made after the OBJ export), `extent` (0 maps), `keyframes` (0 maps; fingerprints are off by default, D-042). If we ever want "which maps have 3D / room areas" at a glance, read those fields, or bump the format only when the SHAPE changes.
