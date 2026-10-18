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

## Format 4 (current)

**Update 2026-10-18 (Claude):** format 4 = format 3 plus the OPTIONAL per-node key `stairs`, written only for nodes of kind `stairs` or `elevator` (branch `stairs-multifloor`):
`"stairs": { "direction": "up" | "down" | "both", "railings": "left" | "right" | "both" | "neither", "stepCount": int }` — every field itself optional, and the whole object absent when the volunteer recorded nothing. Maps without it stay valid and decode with none.
Why it exists: the two ends of one staircase are recorded in SEPARATE maps (one per floor) and matched across them by the node's LABEL, so `direction` is what tells the two ends apart; `railings` has no other possible source, because ARKit's mesh classification has no railing class. Nothing reads any of it yet — `BuildingMap` still has no `building`/`floor` field, so floors are not matched.
Validated in `MapBundle.validate()` only by being optional and decodable; `tools/validate_map.py` (CURRENT_SCHEMA = 4), `web/router.js` and the SQL migrations ACCEPT format 4 but do not inspect the `stairs` object — same position `keyframes` is in. Example: `docs/map-format/map-v4.json`. `schemaVersion` must be 1...4. Older apps ignore `stairs`.
**Note for U3:** `web/router.js` and `web/geometry-tests.js` were edited by me (B/A area) to accept 4, because the bump otherwise made the viewer reject every map the app writes. The test that asserted "format 4 is unsupported" now asserts it for 5.

## ~~Format 3 (current)~~ Format 3 (readable; was current until format 4)

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
- The native 3D model is `model.usdz` next to `map.json` (not listed in the map JSON); the web viewer reads OBJ. A USDZ-to-OBJ export is not built.


## Update 2026-10-18 (Codex) ? preserved U3 integration notes

The following U3 notes are retained for history. Current integration details are in the newest WORKLOG entry; earlier status claims describe their original checkout.

# Map file format â€” specification per version

Added 2026-10-17 (Claude, CONTRACT CHANGE). Source of truth in code: `Model/MapTypes.swift`, `Model/BuildingMap.swift`
(`MapSchema`), `Model/MapStore.swift` (`MapBundle.validate`). Checkers: `tools/validate_map.py`, `supabase/migrations/`.
Example file per version: `docs/map-format/map-v1.json`, `docs/map-format/map-v2.json`.

## Two different version numbers (do not confuse)

| Field | Meaning | Changes when |
|---|---|---|
| `schemaVersion` | **Format** of the JSON (this document) | the SHAPE of the file changes (rare, announced as CONTRACT CHANGE) |
| `version` | **Content revision** of one building's map | someone extends/saves/merges the map (sync uses it to see who is newer) |

## Rules that apply to every version

- Units: metres. Frame: the ARKit world frame of the scan session (+x right, +y up, âˆ’z forward). `SIMD3<Float>` is a 3-element array `[x, y, z]`.
- Unknown extra keys are ignored on read (Swift `Codable`), so a NEWER file with only added optional keys is still readable by an older app.
- Files are written with sorted keys, pretty-printed (stable git diffs).
- **Reading:** a missing `schemaVersion` means format 1. Any format from 1 to the app's current one is accepted and **migrated in memory** to the current format; saving writes the current format. A format **newer** than the app understands is **refused** with "â€¦newer than this app understands. Update Waypoint." (never half-read).
- **Writing:** always the app's current format.
- The server (`canonical_buildings.map_json`) stores whatever JSON it is given; readers migrate on load, so rows written before format 2 stay valid.
- Limits (all versions): â‰¤ 5 000 nodes, â‰¤ 20 000 edges, â‰¤ 50 MB per world map, segment ids `[A-Za-z0-9_-]{1,64}`, finite positions, unique node ids, every edge joins two existing different nodes, edge `distance` within max(0.5 m, 25 %) of the straight-line distance of its nodes.

## ~~Format 2 (current)~~ Format 2 (legacy)

**Update 2026-10-17 (Codex, U3):** current format is 3. The format-2 description below is retained; the full schema-3 contract follows it.

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
| `schemaVersion` | integer | yes on write (2); optional on read (missing = 1) | must be â‰¥ 1 and â‰¤ 2 |
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

## Format 1 (legacy, still readable)

Identical to format 2 **except there is no `schemaVersion` key**. All files written before 2026-10-17 are format 1, including `Samples/rice-hall-sample.json` at that time. Migration 1 â†’ 2: none needed beyond setting `schemaVersion = 2` on load.

## How to add format N+1 (checklist)

1. Add a section above for the new format and a fixture `docs/map-format/map-vN+1.json`.
2. Swift: bump `MapSchema.current`, add the conversion in `MapSchema.migrate`, keep decoding every older fixture (`MapSchemaTests`).
3. Python: bump `CURRENT_SCHEMA` in `tools/validate_map.py` and add a test.
4. SQL: if the server must reject/convert the new shape, add a new migration (never edit applied ones).
5. Tag the WORKLOG entry `CONTRACT CHANGE`, update `Samples/rice-hall-sample.json`, MODULES.md and TESTING.md.

## Known limits

The Swift, Python and SQL checks are three separate implementations of the same rules; `MapSchemaTests` and `tools/test_validate_map.py` both run the same two fixtures, which is what keeps them aligned.


---

# Map file format on U3 — schema 3

CONTRACT CHANGE, 2026-10-17. This branch builds on main's serialized versioning
(`34e9a73`) and ports RoomExtent/RoomExtractor from navigation-overhaul (`6c892a1`).
It does not replace main's versioning with the navigation branch's static constant.
Native source: Model/BuildingMap.swift, MapTypes.swift, MeshAsset.swift, MapStore.swift.

## Two version numbers

| Field | Meaning |
|---|---|
| `schemaVersion` | JSON format. U3 writes **3**, reads 1 through 3, rejects future versions. |
| `version` | Content revision of a building. Increments when extended/merged/published. |

Format 1 omits schemaVersion. Format 2 explicitly writes 2 but has the same graph
fields. Format 3 adds optional `nodes[].extent`, a `meshAssets` array, and optional
bundle `meshFiles`. Migration preserves IDs, positions, labels, marker and edges;
absent geometry stays nil/empty. Existing maps do NOT acquire invented walls.
Unofficial legacy maps from navigation-overhaul with extent but no format key
can still decode their known extent fields and save as schema 3.

Fixtures: `docs/map-format/map-v1.json`, `map-v2.json`, `map-v3.json`.
The original format 1/2 fixtures are copied from origin/main. Format 3 and its
`mesh-v3.obj` example are synthetic demonstration data, not a Rice Hall survey.

## Navigation graph (retained)

Map: `id` (building UUID), `name`, `version`, `schemaVersion`, `nodes`, `edges`,
optional `marker`, and `meshAssets` (defaults to []). Units are meters. Coordinates
use the scan's ARKit world frame: +x right, +y up, camera facing -z. Extensions load
an existing world map before recording and retain that same coordinate frame.

Node: `id`, `kind`, optional `label`, `position:[x,y,z]`, `segmentId`, `createdBy`,
optional `extent`. Edge: `from`, `to`, `distance`, optional `hazard`. Node/hazard
values, maximum graph sizes, safe segment alphabet and distance validation remain
unchanged. A room rectangle does not prove that an edge is physically walkable.

## Room extent

Only room nodes may carry an extent:

```json
{
  "center": [3, 0, -9],
  "halfExtents": [1.5, 2],
  "yaw": 0,
  "areaSquareMeters": 12
}
```

Center is at floor level. Half-extents are local x/z half-widths, yaw is radians
around +y, and enclosed area must be positive and no greater than rectangle area
(0.01 m² numerical tolerance). Optional `heightMeters` must be positive/finite and
is reserved for measured ceiling height. Current extraction leaves it absent;
the viewer draws a footprint, never fabricates a wall height.

On room tagging, nearby classified floor faces estimate floor height, while
classified wall/door samples feed a flood fill. No floor or enclosure => no extent.
Open doors and incomplete scans may fail extraction. Capture quality is
UNVERIFIED ON DEVICE. The rectangle is an approximation, not a detailed floor plan.

## Mesh manifest and payloads

Each MeshAsset has `id` (UUID), `segmentId`, `format:"obj"`,
`coordinateFrame:"map"`, `byteCount`, lowercase SHA-256 `sha256`, `boundsMin` and
`boundsMax` ([x,y,z]). Optional `storageOwner` (UUID) is assigned during publication
and is required in cloud manifests. IDs are unique; referenced segments must exist.

The payload is an untextured, triangular OBJ file containing actual captured
vertices and faces. ARMeshAnchor transforms are baked into vertices, so geometry,
room extents and the navigation graph share map coordinates; no extra transform
matrix or arbitrary external URL is needed. The pipeline does not export textures,
photos, face classifications, semantic objects, raw depth frames or a complete
floor/ceiling segmentation. Missing surfaces remain missing.

Limits: 40,000,000 bytes per asset, 80,000,000 total declared mesh bytes per map,
100 asset entries, 500,000 vertices and 1,000,000 triangles per exported OBJ.
Data size and checksum are checked at bundle import/download; browser rendering
also checks OBJ indices and declared bounds. Rendering samples up to about 12,000
triangles for responsiveness; full source files remain unchanged.

Storage:

- Local: `<map UUID>/mesh-<asset UUID>.obj` alongside map.json and world maps.
- Cloud: `meshes/<owner UUID>/<map UUID>/<asset UUID>.obj` (lowercase UUIDs).
- Bundle: `{ "map": ..., "worldMaps": ..., "meshFiles": { "<asset UUID>": "<base64 bytes>" } }`.
  meshFiles may be absent for graph/metadata-only data. A locally created asset
  without a cloud owner MUST have its file before publication; mesh assets upload
  before their canonical manifest. Referenced missing cloud files fail explicitly.

## Deployment and merge rules

Run migration **0004_rich_map_schema.sql after 0003**, then all three SQL test
scripts. 0004 preserves 0003's checked shortcut wrapper and replaces its internal
merge implementation. It promotes successful writes to schema 3, keeps omitted
old extents/assets during stale uploads, permits filling an absent room extent,
and rejects conflicting extent replacements or mesh ID reuse with different
metadata. New mesh owners must match the uploader. Shared mesh reads follow the
canonical manifest rather than legacy contributor rows. Existing DB rows are not
rewritten until their next publication. No live migration was run by the agent.

Native local merge also preserves extents/assets and rejects conflicting asset
metadata. Payloads are written before map.json so a failed payload write cannot
publish a new local manifest referencing bytes that were not saved.

Main's schema-2 readers intentionally reject schema 3; update clients together.
Older unversioned clients may ignore richer fields locally; do not use them to
re-export rich bundles. The new server preserves omitted rich data, but cannot
repair geometry dropped in an old client's local export.

Before merging this U3 work with newer main, retain its MapSchema framework and
route-memory methods; do not copy this older branch's whole MapStore over main.


**Update 2026-10-18 (Codex, mesh integration):** Retain incoming notes below; final integration behavior is recorded in WORKLOG.



**Update 2026-10-18 (Codex, U3 team sync):** Also retain incoming notes below.

- ~~The native 3D model is `model.usdz` next to `map.json` (not listed in the map JSON); the web viewer reads OBJ. A USDZ-to-OBJ export is not built.~~
  **Update 2026-10-18 (Claude, branch `feature/web-mesh-obj`):** the app now ALSO writes a web copy of the scan as `mesh-<asset id>.obj` next to `map.json` and lists it in `meshAssets` (`ObjExport`, `MapStore.attachMesh`); `SyncEngine.push` uploads it to `meshes/<owner>/<map>/<asset>.obj` and lists it on the server with `publish_mesh_assets` (migration ~~0007~~ **Update 2026-10-18 (Claude):** 0008 (renamed: a different 0007 exists on the live project), not yet applied). `model.usdz` stays the phone's own viewer format. UNVERIFIED ON DEVICE.

**Update 2026-10-18 (Claude): versioning check on real data.** Behaviour is as designed: `schemaVersion` is the FORMAT of the file, stamped with the app's current format (3) whenever a map is saved; it does NOT say how rich one map is. Evidence: all 5 scans on Sachin's phone (made on different days, the oldest before OBJ export existed) and all 8 live cloud rows say `schemaVersion` 3; formats 1, 2 and 3 fixtures, the bundled-style sample and every real map pass `tools/validate_map.py`; `MapSchemaTests` 9/9. Richness is carried by the OPTIONAL fields instead: `meshAssets` (2 of 5 scans: the two made after the OBJ export), `extent` (0 maps), `keyframes` (0 maps; fingerprints are off by default, D-042). If we ever want "which maps have 3D / room areas" at a glance, read those fields, or bump the format only when the SHAPE changes.


**Update 2026-10-18 (Codex, U3 conflict integration):** Combined format is schema 4 with optional stairs, retaining extents and keyframes. Mesh approval requires publish_mesh_assets after upload. Migration order: audit 0006, secure mesh 0008, rich format 0009, validator alias 0010. Browser 58/58, UI 23/23 and Python 22/22 pass. Native tests/typecheck unavailable on Windows; SQL not executed. UNVERIFIED ON DEVICE.


**Update 2026-10-18 (Codex, U3 team sync):** Also retain incoming notes below.
