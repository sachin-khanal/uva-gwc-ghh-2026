# Roadmap — what to work on now (revision 2, ~~PROPOSED~~ IN PROGRESS)

~~Status: **proposed, needs team OK.**~~ **Update 2026-10-17:** the team asked to keep building, so this plan is in progress (build block 1 done, see below). Written 2026-10-17 after the direction change: native iPhone app
(sideloaded, not published), **Supabase free tier** as backend, and a **Polycam-style LiDAR
scanner** (live mesh overlay + bounding box → saved 3D model) that also feeds indoor navigation.
Design details: `Architecture.md` section 10. Decisions: `docs/DECISIONS.md` D-013..D-016.

## The product loop (one sentence each)

1. **Scan** — volunteer walks; sees the LiDAR mesh grow live over the camera, inside an adjustable
   bounding box; tags doors/rooms. (Polycam-like; hero feature for judges.)
2. **Review** — saved scan opens as a 3D model (orbit/zoom) with its nav points drawn on it.
3. **Library** — scans/maps sync to Supabase; any team phone can download them.
4. **Navigate** — blind user is guided through a downloaded map by spatial audio + haptics.

Navigation stays the demo's climax; the scanner is how the map gets made and what makes it look good.

## Workstreams (can all run in parallel)

| # | Stream | Owner | Deliverable ("done" = ) | Needs phone? | Depends on |
|---|---|---|---|---|---|
| 0 | **Device bring-up** | everyone | App installs and launches on each team iPhone; permissions accepted (docs/SETUP.md §3) | yes | nothing — **do first, blocks all device testing** |
| 1 | **Live scan view** | A | RealityKit AR view shows live mesh overlay (colored by surface class), scan bounding box (wireframe, resizable), HUD: triangles, area, tracking quality; replaces the status-text-only volunteer screen | yes | 0 |
| 2 | **Relocalization proof** | A | Save scan → kill app → relaunch → app relocalizes in the same hallway ≥ 4/5 tries; marker fallback works. **Highest risk; start early** | yes | 0 |
| 3 | **Navigation bring-up with a simulated walker** | B | "Simulate" debug mode feeds a scripted pose path along the sample map so audio/haptics/speech can be tuned without a scan or relocalization | yes (audio/haptics) | 0; code can be written now |
| 4 | **Mesh export + 3D preview** | C | Stop scan → mesh (ARMeshAnchors) cropped to the bounding box → exported as USDZ (< 40 MB) → opens in an in-app 3D viewer; nav nodes shown as pins | yes | 1 (needs a mesh) |
| 5 | **Depth/obstacle calibration** | C | Obstacle thresholds and depth region tuned in a real corridor; stairs/drop-off check | yes | 0 |
| 6 | **Supabase backend + sync** | D | Project + schema + RLS applied; app signs in anonymously; upload/download a map bundle and mesh; library screen lists maps | no for backend code; yes to run | none for schema/client; UI after 0 |
| 7 | **Demo hardening** | D | Printed marker, escort script, pre-loaded maps, offline fallback (Multipeer/AirDrop), backup video | yes | 2, 3, 6 |

### Recommended assignment for the next block

- **A:** streams 0 → 1 → 2.
- **B:** streams 0 → 3, then audio tuning with headphones.
- **C:** streams 0 → 5, then 4 when A's mesh exists.
- **D:** streams 0 → 6 (SQL + client first; no phone needed), then 7.

## What an agent can start RIGHT NOW without a phone (and prove with `make test`)

| Task | Where | Proof |
|---|---|---|
| Supabase SQL: tables, storage buckets, RLS policies | `supabase/migrations/*.sql` (new) | review + run in the Supabase SQL editor |
| Supabase REST client (anonymous auth, upsert/list maps, upload/download files) with `URLSession` | `Package/WaypointCore/Sources/WaypointCore/Cloud/` | `make test` with a mocked `URLProtocol` |
| Cloud DTOs ↔ `BuildingMap`/`MapBundle` mapping, size caps, validation on download | same | `make test` |
| Bounding-box math: oriented box from points, crop test, volume/area | `Package/WaypointCore/.../Scan/BoundingBox.swift` (new) | `make test` |
| Mesh → export plan (decimation target from byte budget), pose simulator path generator | `.../Scan`, `.../Routing` | `make test` |
| Live scan view, mesh export, 3D viewer, simulate-mode UI | `Waypoint/` | `make typecheck` only; **UNVERIFIED ON DEVICE** |

## Update 2026-10-17 — status after build block 1 (see WORKLOG 13:30)

| # | Stream | Status now | Next step |
|---|---|---|---|
| 0 | Device bring-up | NOT DONE (nobody has run the app on a phone yet) | `docs/SETUP.md` §3 |
| 1 | Live scan view | SCAFFOLD (`Waypoint/Scan/*`, `CaptureController`), box math tested, UNVERIFIED ON DEVICE | TESTING.md 3.1-3.4; colour mesh by class |
| 2 | Relocalization proof | NOT STARTED on device (code is scaffolded) | TESTING.md 3.5 |
| 3 | Simulated walker | DONE in logic + end-to-end test; Simulate UI SCAFFOLD | TESTING.md 2.2-2.6 with headphones |
| 4 | Mesh export + 3D preview | ONLY the size budget (`ExportBudget`) | build `MeshExporter` (ModelIO -> USDZ) + viewer (C) |
| 5 | Depth/obstacle calibration | NOT STARTED (detector scaffolded) | TESTING.md 3.7 |
| 6 | Supabase backend + sync | Client + `SyncEngine` DONE vs mock (11 tests); SQL written; Cloud UI SCAFFOLD; never run on a real project | create project, SETUP.md §5, TESTING.md 2.9 |
| 7 | Demo hardening | NOT STARTED | after 2, 3, 6 |

The table "What an agent can start RIGHT NOW" above is mostly done: ~~Supabase SQL~~ written; ~~REST client~~ done (mock-tested); ~~cloud DTO mapping, size caps, validation~~ done;
~~bounding-box math~~ done; ~~export plan~~ budget math done; ~~pose simulator~~ done. Still open there: the exporter itself and anything needing a phone.

## Milestones (checkpoints, not clock times)

- **M0 — Everyone runs the app** (stream 0).
- **M1 — Scan & see it:** live mesh + bounding box on a phone; save works.
- **M2 — Come back & find yourself:** relocalization proven (stream 2). If it fails, QR marker becomes mandatory.
- **M3 — Walk the audio:** simulated walker + real scan produce correct left/right/straight cues.
- **M4 — Cloud:** map/scan uploaded from phone 1 appears and is usable on phone 2.
- **M5 — Rice Hall dress rehearsal** with a blindfolded teammate and an escort.

## Cut lines (drop in this order if time runs out)

1. Public/shared gallery, scan thumbnails → keep a private library only.
2. Cloud sync → AirDrop/Multipeer export (already built).
3. Vertex-color or textured mesh → untextured classified mesh.
4. 3D viewer → just show the live scan overlay and a saved screenshot.
5. Obstacle detection polish → single "something close" cue.
**Never cut:** scan → relocalize → audio-guided route to one room, with an escort.

## Out of scope (explicitly)

Photogrammetry/photo scanning, measuring tools, floor-plan CAD export, AI object detection beyond
signs, Android, App Store release, user accounts with email/password (anonymous auth only).
