# Waypoint — Architecture

Indoor navigation for blind users. A sighted volunteer scans a building once; a blind user later navigates it by spatial audio and haptics. Demo: blindfolded judge walks to a room in Rice Hall.

**Budget:** 24 hours, 4 people. **Signing:** free Apple ID (no paid developer profile).

---

## 1. Constraints that shape everything

| Constraint | Consequence |
|---|---|
| LiDAR only on Pro iPhones (12 Pro+) | No simulator for AR/depth. Every AR feature is tested on a physical phone. |
| Free provisioning profile | Apps expire after 7 days (fine for 24h). Max 3 sideloaded apps per device. No TestFlight, iCloud/CloudKit, push, or Associated Domains. Each dev builds with their own Apple ID and a unique bundle ID suffix. |
| No backend, no accounts | Sync is peer-to-peer or local-network only. Maps are files. |
| Campus Wi-Fi often isolates clients | Do not depend on Wi-Fi LAN reachability. Use MultipeerConnectivity (works over Bluetooth/peer-to-peer Wi-Fi) with a file-export fallback. |
| Blind user, safety-adjacent | Audio/haptic feedback must degrade gracefully: if tracking is lost, say so and stop issuing directions. |

**Setup checklist (everyone, before hour 1):** Xcode 16+, iPhone Developer Mode on, device trusted, unique bundle ID (`edu.virginia.waypoint.<name>`), Local Network + Camera permissions accepted once. Either MacBook can build; use the Pro for long builds if the Air struggles.

Minimum target: **iOS 17**, Swift 5.10+, SwiftUI, no third-party dependencies.

---

## 2. System overview

```
            ┌──────────── Volunteer mode ────────────┐      ┌──────────── Navigator mode ───────────┐
            │ ARSession + LiDAR mesh                  │      │ ARSession (relocalize against map)     │
            │   ├─ Breadcrumb recorder (every ~1.5 m) │      │   ├─ Relocalizer (world map + marker)  │
            │   ├─ POI tagger (door/stairs/label)     │      │   ├─ Router (A* on waypoint graph)     │
            │   └─ OCR suggester (room numbers)       │      │   ├─ Guidance (audio + haptics + TTS)  │
            └───────────────┬─────────────────────────┘      │   ├─ Obstacle detector (LiDAR depth)   │
                            │ BuildingMap bundle             │   └─ OCR confirmer (signs)             │
                            ▼                                └───────────────▲────────────────────────┘
                    ┌────────────────┐        Multipeer / file export         │
                    │   MapStore     │ ───────────────────────────────────────┘
                    │ (local disk)   │ ◄── extend: merge new nodes into existing map
                    └────────────────┘
```

One app, two modes chosen at launch. Both modes share `MapStore`, `MapSync`, and the `ARSession` wrapper.

---

## 3. Data model (the contract between all four people)

A **BuildingMap** is a folder/bundle. Agree on this on hour 0; everything else plugs into it.

```swift
struct BuildingMap: Codable {
    var id: UUID
    var name: String                 // "Rice Hall, floor 1"
    var version: Int                 // bumps on every extend
    var nodes: [MapNode]
    var edges: [MapEdge]
    var anchorMarker: MarkerRef?     // fallback relocalization (see §4.2)
}

struct MapNode: Codable, Identifiable {   // named MapNode, not Node (decision D-010)
    var id: UUID
    var kind: NodeKind               // .corridor, .door, .stairs, .elevator, .room, .junction
    var label: String?               // "Room 204", "Stairs up"
    var position: SIMD3<Float>       // in map coordinate frame (meters)
    var segmentId: String            // which ARWorldMap segment it belongs to
    var createdBy: String            // device name, for extend/merge
}

struct MapEdge: Codable {
    var from: UUID, to: UUID
    var distance: Float
    var hazard: Hazard?              // .stairs, .narrow, .doorThreshold
}
```

On disk: `map.json` (above) + `worldmap.arworldmap` (archived `ARWorldMap`) per **segment**. A building = one or more segments (see §4.2). A `segmentId` on each node ties it to the right world map. Keep the JSON human-readable; it is the debugging tool.

---

## 4. Components

### 4.1 Capture (Volunteer mode)
- `ARWorldTrackingConfiguration` with `sceneReconstruction = .mesh`, `planeDetection = [.horizontal, .vertical]`, `environmentTexturing` off (saves power/memory).
- **Breadcrumbs:** drop a `.corridor` node whenever the camera has moved >1.5 m from the last node, and connect to it. Walking the corridor yields the graph with no manual work.
- **POI tagging:** big buttons (Door, Stairs, Elevator, Room…) drop a typed node at the camera position projected ~1 m forward; text field for the label. Keep this under two taps.
- **Save:** `session.getCurrentWorldMap` → archive → `MapStore`. Show `worldMappingStatus` and only enable Save at `.mapped`.
- The LiDAR mesh is used live for the mapping-quality feedback and not stored (size).

### 4.2 Relocalization (Navigator mode) — highest risk
Goal: a returning phone knows where it is inside the saved map.
- **Primary:** set `configuration.initialWorldMap`; wait for `trackingState == .normal` and `worldMappingStatus` OK. Anchor all node positions in that world frame.
- **Fallback (build it, don't hope):** a printed **QR code / `ARReferenceImage`** taped at the start of the route. Scan it → `ARImageAnchor` gives a known pose → align map frame to it. Works when world-map relocalization fails in repetitive hallways.
- **Scope control:** one world map per *segment* (one hallway/floor wing, ≲ 30 m). ARKit maps degrade over large areas. Stitch segments by shared marker/known junction node rather than one giant scan.
- On `.limited`/`.notAvailable` tracking: stop guidance, say "I've lost my position, hold still", resume on recovery.

### 4.3 Routing
- Graph from `BuildingMap`; A* over edges (distance + hazard penalty; avoid stairs unless the destination demands it).
- Destination chosen by label ("Room 204") via search or voice (`SFSpeechRecognizer`, optional stretch).
- Router outputs a stream of `GuidanceInstruction { bearing, distance, kind, hazard }` for the next waypoint, advancing when within ~1 m.

### 4.4 Guidance (audio + haptics)
- **Spatial beacon:** `AVAudioEngine` + `AVAudioEnvironmentNode`, one `AVAudioPlayerNode` placed at the next waypoint's position in the listener's frame; listener orientation updated from the AR camera each frame. The user literally hears the turn from that direction. Use AirPods/wired headphones for the demo (spatial audio needs headphones; test mono speaker behavior too).
- **Speech:** `AVSpeechSynthesizer` for discrete events ("Door on your left", "Stairs in 3 meters", "Arrived at room 204"). Rate-limit and queue so it never talks over itself.
- **Haptics:** `CoreHaptics` — directional cue pattern (left/right pulses relative to heading), continuous rising pulse rate for obstacles, distinct pattern for arrival.
- Priority order: obstacle warning > hazard > turn > ambient beacon.

### 4.5 Obstacle detection (LiDAR depth)
- Enable `frameSemantics = .sceneDepth` (iPhone Pro). Per frame (throttled to ~10 Hz) sample the `depthMap` in a central forward cone (roughly a body-width × head-to-knee region, mapped from the camera frustum).
- If the nearest valid depth in the cone < ~1.2 m → warn; < ~0.6 m → stop alert. Use the `confidenceMap` to drop low-confidence pixels. Add hysteresis to avoid flicker.
- Stretch: down-ward region for drop-offs / stairs descending.

### 4.6 Sign / room-number reading (on-device CV)
- `VNRecognizeTextRequest` (`.accurate`) on a throttled subset of `ARFrame.capturedImage` (~2 Hz), orientation-corrected.
- Filter with a room-number regex (`\b\d{3}[A-Z]?\b` and a few Rice Hall conventions); require N consistent reads before accepting.
- **Volunteer mode:** suggest a label for the nearest node ("Looks like Room 204 — add?"). Human confirms, so OCR errors never poison the map.
- **Navigator mode:** announce "Room 204 on your right" and use it to confirm progress.

### 4.7 Map sync & extend
- `MapSync` wraps **MultipeerConnectivity** (`MCSession`, auto-discovery with a shared service type `waypoint-map`). Needs `NSLocalNetworkUsageDescription` + `NSBonjourServices` in Info.plist.
- Protocol: peers exchange `{mapId, version}` headers; the one with the older version requests the bundle; transfer via `sendResource`.
- **Extend:** a volunteer loads an existing map, relocalizes into it, then walks new territory; new nodes carry `createdBy` and merge by UUID union. Conflicts (same label twice) are kept and flagged, last-writer-wins on position is *not* attempted.
- **Fallback:** export bundle via the iOS share sheet (AirDrop works without any signing). This is the demo insurance if Multipeer misbehaves.

---

## 5. Module / repo layout

> Implemented in the first scaffold. The authoritative, always-current version (owners, status,
> interfaces) is [docs/MODULES.md](docs/MODULES.md); decisions are in [docs/DECISIONS.md](docs/DECISIONS.md).

```
Package/WaypointCore/        // pure logic, unit-tested on the Mac with `make test` (no phone needed)
  Sources/WaypointCore/
    Model/        MapTypes, BuildingMap, MapStore, MapBuilder      (shared contract; frozen in hour 2)
    Geometry/     Geometry                                          (A/B)
    Routing/      WaypointGraph, Router, RouteFollower, ...         (B)
    Guidance/     FeedbackPlanner                                   (B)
    Vision/       ObstacleClassifier, RoomNumberParser              (C)
Waypoint/                    // iOS app: only Apple-framework glue (needs a phone)
  App/ UI/                   // entry, AppState, screens                      (D)
  Capture/ Relocalization/   // ARSession, world map, QR fallback              (A)
  Navigation/                // per-frame integration loop                     (B + A)
  Guidance/                  // spatial audio, haptics, speech                 (B)
  Vision/                    // LiDAR depth read, Vision OCR                   (C)
  Sync/                      // MultipeerConnectivity                          (D)
Samples/  Config/  project.yml  Makefile  scripts/  docs/
```

Build system (decision D-004): **XcodeGen** generates the git-ignored `Waypoint.xcodeproj` from
`project.yml`, so there are no `.pbxproj` merge conflicts, and everything runs from the CLI via the
`Makefile` (`make help`). This replaces the earlier idea of Xcode 16 synchronized folders. The
`*Controller`/guide classes in the app target use the protocols below as their seams; in the scaffold
the same decoupling is achieved by keeping decisions in `WaypointCore` (e.g. `FeedbackPlanner`) and
feeding it plain values (positions, depth readings), so B and C can test without waiting for A.

```swift
protocol PoseProvider { var pose: simd_float4x4 { get }; var isTracking: Bool { get } }
protocol GuidanceSink { func present(_ i: GuidanceInstruction) }
protocol ObstacleSource { var nearestObstacle: Float? { get } }
```

(These three protocols are the original sketch and are **not yet implemented**; the scaffold passes
`ARFrame`s through `Relocalizer.onFrame` instead. Introduce them only if mocking becomes necessary.)

---

## 6. Team split and timeline (24h)

| Person | Owns | First deliverable |
|---|---|---|
| **A — AR/Maps** | Capture, world map save/load, relocalization + QR fallback | Save a world map, relocalize a fresh launch against it (hour ~6) |
| **B — Navigation/Feedback** | Graph, A*, spatial audio, haptics, TTS | Beacon audibly pans toward a hard-coded waypoint (hour ~5) |
| **C — Vision** | OCR pipeline, obstacle detection | Console log of recognized room numbers and nearest-depth values (hour ~5) |
| **D — App/Sync/Integration** | Shell, UI, Multipeer + export, project file, demo script | Two phones exchange a map JSON (hour ~6) |

| Hours | Milestone |
|---|---|
| 0–2 | Setup checklist, freeze `Model/` contract, skeleton app builds on all 4 phones/Macs |
| 2–8 | Each module works standalone against mocks / hard-coded data |
| 8–14 | **Integration #1:** scan a real hallway → save → relocalize → follow audio to a tagged door |
| 14–18 | Integrate OCR labels + obstacle warnings; Multipeer sync; extend flow |
| 18–21 | Scan Rice Hall for real; tune thresholds; rehearse with a blindfolded teammate |
| 21–23 | Bug-fix only; record backup demo video; print QR marker |
| 23–24 | Freeze. Charge phones. Pre-load the final map onto every demo device. |

Test early in **any real corridor** (dorm, Rice Hall itself) rather than at a desk; desk testing hides the relocalization and depth problems.

---

## 7. Risks and cut lines

| Risk | Mitigation | Cut line if it fails |
|---|---|---|
| Relocalization flaky in Rice Hall | QR/image-anchor fallback; short segments; scan in consistent lighting | Demo starts at the QR marker every time |
| Multipeer unreliable | AirDrop/share-sheet export; pre-load map before demo | Drop live sync; sync becomes file transfer |
| OCR misreads signs | Human-confirmed labels in capture; consistency voting | Labels typed manually by the volunteer |
| Obstacle detection false positives | Confidence mask, hysteresis, tunable thresholds | Ship a single "something close ahead" haptic |
| Spatial audio weak on phone speaker | Headphones/AirPods for demo | Add left/right-biased tone + speech cues |
| Free-profile install hiccups | Every dev signs for their own phones; keep phones plugged in once before the demo | Demo on two phones max |
| Safety of blindfolded judge | Teammate walks beside them with a hand ready; route avoids stairs | Never run the demo unaccompanied |

**Must-have for demo:** scan → tagged map → relocalize → spatial-audio route to one room, with a trusted escort.
**Should-have:** obstacle warnings, OCR-assisted labels.
**Nice-to-have:** live Multipeer sync and extend, voice destination input, multi-segment stitching.

---

## 8. Accessibility notes
- Navigator UI is audio/haptic-first; every control labelled for VoiceOver with large hit areas.
- Never rely on the screen for the blind user: start navigation via a single large "Start" target or voice.
- Keep screen on (`isIdleTimerDisabled`) during navigation; warn on low battery or thermal state `.serious`.
- Spoken status for state changes: "Searching for position", "Position found", "Tracking lost".

## 9. Open decisions (resolve in hour 0)
1. Final destination room and exact route in Rice Hall (walk it ahead of time).
2. Headphones for the demo (AirPods vs wired) — it affects the spatial audio design.
3. Whether the QR marker is mandatory in the demo or only a fallback.
4. One shared Apple ID for signing vs each dev signing their own phone.

---

## 10. Revision 2 (PROPOSED, 2026-10-17): Supabase backend and Polycam-style live scanner

Sections 1-9 describe the original local-only design and remain valid unless listed here.
Roadmap and parallel workstreams: [docs/ROADMAP.md](docs/ROADMAP.md).

### 10.1 What changed
- Native iPhone app, sideloaded (free Apple ID), never published. Unchanged from section 1.
- **Backend: Supabase free tier** (Postgres + Storage + anonymous auth). Replaces "no server" as the
  primary sync path. MultipeerConnectivity and AirDrop export stay as the **offline fallback**.
- **Scanner upgraded** from "breadcrumbs only" to a Polycam-style LiDAR scan: live mesh overlay,
  adjustable bounding box, saved 3D model with navigation pins.

### 10.2 Live scanner design (volunteer mode)
- ARKit: `sceneReconstruction = .meshWithClassification` (falls back to `.mesh`) on Pro iPhones.
  Each `ARMeshAnchor` carries vertices, faces, and a per-face class (wall, floor, ceiling, door, window,
  table, seat). Anchors update as the mesh grows.
- Rendering: RealityKit `ARView`. Start with the built-in `debugOptions: .showSceneUnderstanding`
  for a first live overlay, then replace with one `ModelEntity` per anchor to colour by class.
- Bounding box: gravity-aligned box (yaw only) fit to the mesh vertices, drawn as a wireframe, with
  handles to shrink/grow. The box is also the crop volume for export and the "scan area" shown in the HUD.
  Box math lives in `WaypointCore` (`Scan/BoundingBox.swift`) so it is unit-tested.
- Export: crop anchors to the box, assemble `MDLMesh` via ModelIO, write USDZ. Byte budget 40 MB per
  file (Supabase free tier limit is 50 MB per upload); decimate or drop small anchors to fit.
- Bonus for navigation (stretch): classification gives free door candidates (suggested door nodes)
  and wall/floor information for obstacle checks. Humans still confirm labels.
- Navigation data is unchanged: the mesh is for viewing/export; routing still uses the waypoint graph and
  the `ARWorldMap` for relocalization (section 4.2).

### 10.3 Cloud design (Supabase)
- **Auth:** anonymous sign-in (no signup UI). Each phone gets a user id; Row Level Security uses it.
- **Tables:** `buildings` (id, owner, name, version, map_json jsonb, is_shared, updated_at) and
  `scans` (id, building_id, owner, storage_path, bytes, bbox jsonb, triangle_count, created_at).
- **Storage buckets:** `worldmaps` (ARWorldMap binaries), `meshes` (USDZ). Private; access via RLS on
  `storage.objects` keyed on owner id; shared buildings readable by all authenticated users.
- **Client:** plain REST via `URLSession` (PostgREST + Storage + GoTrue anonymous), implemented in
  `WaypointCore` with an injectable transport so it is unit-tested with a mock. No Supabase SDK (D-014).
- **Trust:** the app ships with the public anon key, so ALL authorization is RLS. Downloaded maps are
  untrusted data: they go through the same `MapBundle.validate()` and user approval as peer-to-peer
  imports (D-012).
- **Free-tier realities (verify in the dashboard):** about 500 MB database, 1 GB storage, 50 MB per
  file, project auto-pauses after about a week of inactivity (wake it before the demo), no SLA.
- **Offline first:** every screen must work with no network; cloud is sync, not a dependency of
  navigation. Pre-load the demo maps onto every phone.

### 10.4 Updated module map (additions)
```
Package/WaypointCore/Sources/WaypointCore/
  Scan/        BoundingBox, ExportBudget                  (A/C)
  Cloud/       SupabaseClient, CloudModels, SyncEngine    (D)
Waypoint/
  Scan/        LiveScanView (RealityKit), MeshExporter, ModelViewer   (A/C)
  Cloud/       LibraryView, AuthSession                                 (D)
supabase/migrations/   SQL schema + RLS                                 (D)
```
