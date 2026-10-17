# Modules — ownership, interfaces, status

Status legend: **DONE** (works and tested as far as possible) · **SCAFFOLD** (compiles, wired, logic
sketched; needs real work/device testing) · **TODO** (not started).
"Tested" means automated tests in `make test`. Nothing involving ARKit/audio/haptics/Multipeer has
been run on a device yet: **all device-facing code is UNVERIFIED ON DEVICE** as of the first scaffold.

Team (fill in real names): **A** = ______ · **B** = ______ · **C** = ______ · **D** = ______

## Layout

```
Package/WaypointCore/            pure logic, tested by `make test` (no Apple UI/AR frameworks)
  Sources/WaypointCore/
    Model/        MapTypes, BuildingMap, MapStore, MapBuilder
    Geometry/     Geometry
    Routing/      WaypointGraph, Router, GuidanceInstruction, RouteFollower
    Guidance/     FeedbackPlanner
    Vision/       ObstacleClassifier, RoomNumberParser (+ConsensusFilter)
  Tests/WaypointCoreTests/   ModelTests, RoutingTests, FeedbackAndVisionTests
Waypoint/                        the iOS app (ARKit/AVFoundation/SwiftUI glue; needs a phone)
  App/ UI/ Capture/ Relocalization/ Navigation/ Guidance/ Vision/ Sync/
Samples/rice-hall-sample.json    hand-written fake map; also bundled in the app and seeded on first launch
Config/  project.yml  Makefile  scripts/    build system
docs/  AGENTS.md  Architecture.md           documentation
```

## Ownership table

| Area | Owner | Files | Status | Tested |
|---|---|---|---|---|
| **Data model & storage** | D (shared contract) | `Model/MapTypes.swift`, `BuildingMap.swift`, `MapStore.swift` | DONE | `ModelTests` |
| **Graph building from scan** | A | `Model/MapBuilder.swift` | DONE (logic) | `RoutingTests.testMapBuilder…` |
| **Geometry / frames** | A (shared with B) | `Geometry/Geometry.swift` | DONE | `RoutingTests.testSignedBearing…`, `testMarkerAlignment…` |
| **AR capture (volunteer)** | A | `Waypoint/Capture/CaptureController.swift` | SCAFFOLD | – (device) |
| **Relocalization** | A | `Waypoint/Relocalization/Relocalizer.swift` | SCAFFOLD | – (device) |
| **Routing** | B | `Routing/WaypointGraph.swift`, `Router.swift`, `RouteFollower.swift`, `GuidanceInstruction.swift` | DONE (logic) | `RoutingTests` |
| **Feedback decisions** | B | `Guidance/FeedbackPlanner.swift` | DONE (logic) | `FeedbackAndVisionTests` |
| **Spatial audio / haptics / speech** | B | `Waypoint/Guidance/*.swift` | SCAFFOLD | – (device, needs headphones) |
| **Navigation integration** | B + A | `Waypoint/Navigation/NavigationController.swift` | SCAFFOLD | – (device) |
| **Obstacle detection** | C | `Vision/ObstacleClassifier.swift` (logic), `Waypoint/Vision/ObstacleDetector.swift` (LiDAR read) | logic DONE · detector SCAFFOLD | classifier tested |
| **Sign reading (OCR)** | C | `Vision/RoomNumberParser.swift` (logic), `Waypoint/Vision/SignReader.swift` | logic DONE · reader SCAFFOLD, NOT wired into any screen | parser tested |
| **Map sync** | D | `Waypoint/Sync/MapSync.swift`, `UI/SyncView.swift` | SCAFFOLD | – (needs 2 phones) |
| **App shell & screens** | D | `Waypoint/App/*`, `Waypoint/UI/*` | SCAFFOLD | – |
| **Build system & docs** | D | `project.yml`, `Makefile`, `Config/`, `scripts/`, `docs/`, `AGENTS.md` | DONE | – |

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
