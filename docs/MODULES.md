# Modules — ownership, interfaces, status

**Update 2026-10-17 (Claude):** the Codex/U3 notes below that say tests or SQL are "pending" or "UNVERIFIED" are partly closed: Swift 85/85, typecheck OK, SQL migrations 0001-0003 + both SQL tests PASS locally (stubbed storage schema), Python 9/9. Still open: live-server concurrency and everything on a phone (UNVERIFIED ON DEVICE). New unmerged work: branch `app-ui-workflows` (new Scanner/Navigator UI, `Flows/`, `Services/`).

**Update 2026-10-17 (Codex, U3 request):** existing-building scan extension now has UI/controller wiring and pure MapBuilder attachment logic (SCAFFOLD, new Swift tests pending Mac execution, UNVERIFIED ON DEVICE). Migration 0003 aligns server extension connections with local import rules (SQL execution pending). This supersedes the earlier unfinished scan-extension note below; see WORKLOG and the new TESTING checklist.

**Update 2026-10-17 (Codex, U3):** cloud canonical-map extension implemented in migration 0002 plus Swift client/controller wiring, pending SQL and Mac verification. One building UUID has one shared record; contributors add to it. Previous mock-tested contributor-row status below applies to the old endpoint. See `supabase/CANONICAL_MAPS.md`; scan extension UI remains unfinished.

**Update 2026-10-17 (Codex, U3):** developer map validation tool added at `tools/validate_map.py` with `tools/test_validate_map.py` (9 Python tests passing on Windows). U3 owns it; standalone implementation complete, CI wiring pending (INF-2). No Swift module status changed. See `tools/README.md` for commands and validation limits.

Status legend: **DONE** (works and tested as far as possible) · **SCAFFOLD** (compiles, wired, logic
sketched; needs real work/device testing) · **TODO** (not started).
"Tested" means automated tests in `make test`. Nothing involving ARKit/audio/haptics/Multipeer has
been run on a device yet: **all device-facing code is UNVERIFIED ON DEVICE** as of the first scaffold.
**Update 2026-10-17 (build block 1):** still true — the live scan view, simulate mode, cloud UI and everything else under `Waypoint/` have only been type-checked. The new pure-logic parts (box math, simulator, Supabase client against a mock) are covered by 45 tests.

~~Team (fill in real names): **A** = ______ · **B** = ______ · **C** = ______ · **D** = ______~~
**Update 2026-10-17:** **U1** = Mac Pro + iPhone 16 Pro Max · **U2** = Mac Air + iPhone Pro · **U3** = Windows + iPhone Pro · **U4** = Windows + regular iPhone (no LiDAR). Letters map to people: **A = U1** · **B = U2** · **C = U2 + U3** · **D = U2 + U3 + U4** (details in docs/ROADMAP.md, Revision 3). The "Owner" column below still uses the letters.

## Layout

```
Package/WaypointCore/            pure logic, tested by `make test` (no Apple UI/AR frameworks)
  Sources/WaypointCore/
    Model/        MapTypes, BuildingMap, MapStore, MapBuilder
    Geometry/     Geometry
    Routing/      WaypointGraph, Router, GuidanceInstruction, RouteFollower
    Guidance/     FeedbackPlanner
    Vision/       ObstacleClassifier, RoomNumberParser (+ConsensusFilter)
    Scan/         OrientedBox (scan bounding box), ExportBudget (40 MB export cap)
    Simulation/   PoseSimulator (virtual walker)
    Cloud/        HTTPTransport, CloudModels, SupabaseClient, SyncEngine
  Tests/WaypointCoreTests/   ModelTests, RoutingTests, FeedbackAndVisionTests, ScanAndSimulationTests, CloudTests
Waypoint/                        the iOS app (ARKit/AVFoundation/SwiftUI glue; needs a phone)
  App/ UI/ Capture/ Scan/ Relocalization/ Navigation/ Guidance/ Vision/ Sync/ Cloud/
Samples/rice-hall-sample.json    hand-written fake map; also bundled in the app and seeded on first launch
Config/  project.yml  Makefile  scripts/    build system
supabase/migrations/0001_init.sql  database + storage schema with RLS (run in the Supabase SQL editor)
docs/  AGENTS.md  Architecture.md           documentation
```
**Update 2026-10-17 (Claude):** the block above is missing (code blocks cannot be struck): `supabase/migrations/0002_canonical_maps.sql`, `0003_extension_connections.sql`; `supabase/tests/*.sql`; `supabase/CANONICAL_MAPS.md`; `tools/` (`validate_map.py` + tests); core `Guidance/PhonePosture.swift`, `SpokenPhrases.swift`, `Vision/ObstacleKind.swift`, `Scan/ConvexHull2D.swift`; and tests `AccessibilityGuidanceTests`, `MapExtensionTests` (85 tests total). `Flows/` exists only on branch `app-ui-workflows`.

## Ownership table

| Area | Owner | Files | Status | Tested |
|---|---|---|---|---|
| **Data model & storage** | D (shared contract) | `Model/MapTypes.swift`, `BuildingMap.swift`, `MapStore.swift` | DONE | `ModelTests` |
| **Graph building from scan** | A | `Model/MapBuilder.swift` | DONE (logic) | `RoutingTests.testMapBuilder…` |
| **Geometry / frames** | A (shared with B) | `Geometry/Geometry.swift` | DONE | `RoutingTests.testSignedBearing…`, `testMarkerAlignment…` |
| **AR capture (volunteer)** | A | `Waypoint/Capture/CaptureController.swift` | SCAFFOLD | – (device) |
| **Live LiDAR scan view + bounding box** | A | `Waypoint/Scan/LiveScanView.swift`, `MeshSampler.swift`, `Capture/CaptureController.swift` (stats, box) · core `Scan/OrientedBox.swift` | box math DONE · view SCAFFOLD | `ScanAndSimulationTests` (box) |
| **Mesh export (USDZ) + 3D viewer** | C | core `Scan/ExportBudget.swift` (budget math) | budget DONE · exporter/viewer TODO | budget tested |
| **Simulated walker / Simulate mode** | B | core `Simulation/PoseSimulator.swift`, `Navigation/NavigationController.swift` (`startSimulation`), `UI/NavigatorView.swift` | logic DONE (end-to-end test) · UI SCAFFOLD | `testEndToEndWalkProducesExpectedCues` |
| **Supabase client + sync engine** | D | core `Cloud/*`, `supabase/migrations/0001_init.sql` | client DONE vs mock · ~~SQL + live server UNVERIFIED~~ **Update 2026-10-17 (Claude):** SQL 0001-0003 + tests PASS locally and reported OK in U3's Supabase; live-server concurrency + phone use UNVERIFIED | `CloudTests` |
| **Cloud UI** | D | `Waypoint/Cloud/CloudController.swift`, `UI/SyncView.swift` (Cloud section) | SCAFFOLD | – (needs a Supabase project) |
| **Relocalization** | A | `Waypoint/Relocalization/Relocalizer.swift` | SCAFFOLD | – (device) |
| **Routing** | B | `Routing/WaypointGraph.swift`, `Router.swift`, `RouteFollower.swift`, `GuidanceInstruction.swift` | DONE (logic) | `RoutingTests` |
| **Route memory + live replanning** | B | `Routing/RoutePlanner.swift` (+ `avoiding:` in `Router.swift`) | logic DONE · not wired into NavigationController (TODO B) | `RoutePlannerTests` (10) |
| **Feedback decisions** | B | `Guidance/FeedbackPlanner.swift` | DONE (logic) | `FeedbackAndVisionTests` |
| **Spatial audio / haptics / speech** | B | `Waypoint/Guidance/*.swift` | SCAFFOLD | – (device, needs headphones) |
| **Navigation integration** | B + A | `Waypoint/Navigation/NavigationController.swift` | SCAFFOLD | – (device) |
| **Obstacle detection** | C | `Vision/ObstacleClassifier.swift` (logic), `Waypoint/Vision/ObstacleDetector.swift` (LiDAR read) | logic DONE · detector SCAFFOLD | classifier tested |
| **Sign reading (OCR)** | C | `Vision/RoomNumberParser.swift` (logic), `Waypoint/Vision/SignReader.swift` | logic DONE · reader SCAFFOLD, NOT wired into any screen | parser tested |
| **Map sync** | D | `Waypoint/Sync/MapSync.swift`, `UI/SyncView.swift` | SCAFFOLD | – (needs 2 phones) |
| **App shell & screens** | D | `Waypoint/App/*`, `Waypoint/UI/*` | SCAFFOLD | – |
| **Build system & docs** | D | `project.yml`, `Makefile`, `Config/`, `scripts/`, `docs/`, `AGENTS.md` | DONE | – **Update 2026-10-17 (Claude):** + docs enforcement: `scripts/docs-sync.sh`, `scripts/githooks/pre-commit`, `.claude/settings.json`, `.github/workflows/docs-check.yml` (DONE, tested by `make test-hooks`) |

## Interfaces between areas (the things that must not drift)

| Producer → Consumer | Type / function | Notes |
|---|---|---|
| A → everyone | `BuildingMap`, `MapNode`, `MapEdge`, `MarkerRef` | JSON on disk; frozen contract |
| A (Relocalizer) → B (NavigationController) | `Relocalizer.state`, `mapToWorld`, `onFrame(ARFrame)` | `world = mapToWorld * map` |
| B (RouteFollower) → B (FeedbackPlanner) | `GuidanceInstruction` | map-frame positions |
| C (ObstacleDetector) → C/B | `Float?` nearest depth → `ObstacleClassifier.update` → `ObstacleLevel` | meters |
| C (SignReader) → A/D/B | `onRoomNumberConfirmed(String)` | not wired yet |
| B (FeedbackPlanner) → B (guides) | `FeedbackAction` (`speak`, `haptic`, `beacon`) | carried out in `NavigationController.perform` |
| D (MapSync) ↔ D (MapStore) | `MapBundle` (`.waypointmap` JSON file) | merge on import |

## Known gaps / next steps by owner (starting backlog)

**A** — verify world-map save/relocalize on a real phone (highest risk); add marker reference
images (asset catalog group `WaypointMarkers`) and verify yaw convention; segment rollover;
"extend an existing map" flow (relocalize first, then link the first new breadcrumb to the
nearest existing node — `MapBuilder` currently starts an unlinked chain).
**B** — tune audio on headphones; distance-based ping rate; re-routing when off route; arrival
sound; hysteresis on `turnLeft/Right` announcements so borderline headings do not flicker.
**C** — calibrate depth region and thresholds in a real corridor; percentile instead of min;
downward drop-off check; wire `SignReader` into volunteer (suggest labels) and navigator
(announce rooms); add Rice Hall sign formats to the parser with tests.
**D** — 2-phone sync test; version handshake; polish UI + VoiceOver; demo script; QR marker print;
large single Start target and voice destination input (stretch).

**Update 2026-10-17 — backlog additions after build block 1** (the paragraphs above are kept; these add to them):
**A** — ~~(nothing about the live scanner)~~ replace the debug mesh overlay with per-anchor entities coloured by `ARMeshClassification`; confirm ARView does not take over our session delegate (counters stay at 0 if it does); resizable box handles (currently +/- margin buttons only).
**B** — try Simulate mode with headphones (TESTING.md 2.2-2.6) and tune ping rate, haptic patterns and speech wording; Simulate mode currently starts at the first corridor node.
**C** — build `MeshExporter` (ARMeshAnchors cropped to the box -> `MDLAsset` -> USDZ, check real file size against `ExportBudget`) and an in-app 3D viewer; calibrate obstacle thresholds.
**D** — create the Supabase project (SETUP.md §5), run the SQL, test Upload/Refresh/Download on two phones; add an "open .waypointmap" handler (must show the same approval as peer imports); decide REST vs SDK and public vs team-only sharing (Architecture.md §9).

**Update 2026-10-17 — files added by D-022 (accessibility):** core `Guidance/PhonePosture.swift` (A/B), `Guidance/SpokenPhrases.swift` (B, wording reviewed by U4), `Vision/ObstacleKind.swift` (C); `Routing/RouteFollower.swift` gained look-ahead and landmarks; `Guidance/FeedbackPlanner.swift` was rewritten around them;
app `Waypoint/Vision/ObstacleDetector.swift` (rewritten: world-space, floor/ceiling aware), `Waypoint/Vision/ObstacleIdentifier.swift` (new: mesh class + Vision), `Waypoint/Navigation/NavigationController.swift` (posture + report wiring, corrected camera axes). Tests: `AccessibilityGuidanceTests.swift` (24).
