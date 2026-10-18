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

- ~~**A:** streams 0 → 1 → 2.~~
- ~~**B:** streams 0 → 3, then audio tuning with headphones.~~
- ~~**C:** streams 0 → 5, then 4 when A's mesh exists.~~
- ~~**D:** streams 0 → 6 (SQL + client first; no phone needed), then 7.~~
- **Update 2026-10-17:** ~~assignment by letter~~ superseded by **Revision 3** at the bottom of this file, which assigns every task to a real person (U1-U4) with hardware in mind (two Windows PCs cannot build iOS).

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
| 6 | Supabase backend + sync | Client + `SyncEngine` DONE vs mock (11 tests); SQL written; Cloud UI SCAFFOLD; ~~never run on a real project~~ **Update 2026-10-17 (Claude):** migrations 0002/0003 reported applied in U3's project | create project, SETUP.md §5, TESTING.md 2.9 |
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


---

# Revision 3 — Detailed plan from now to demo, by person (2026-10-17)

**Update 2026-10-17 (Codex, requested by U3):** schema 3 + actual untextured OBJ
export/storage/sync are implemented on U3, alongside room footprints ported from
navigation-overhaul and a 3D web renderer. This advances U3.6/U3.8 for OBJ/web;
USDZ/Quick Look is still separate. Native tests/typecheck, live migration 0004
and physical capture/roundtrip are pending. Browser and Python checks pass; do
not mark the device or export gates complete until those pending checks pass.

**Update 2026-10-17 (Codex, U3 redo):** U3.7 viewer restored locally with canonical library connection, sample mode, local import, labeled canvas plan and selectable routes. 33 logic/API-mock and 13 browser interaction checks PASS. Shared vectors and a Swift consumer test added; live-cloud verification and Mac execution remain pending. No deployment, commit or push.

**Update 2026-10-17 (Codex, explicitly requested by U3):** U1.10 extend-map flow is now implemented as a scaffold in VolunteerView/CaptureController/MapBuilder: select building+saved area, relocalize before recording, attach near an existing corridor, use a unique segment, preserve map identity. U3 also added migration 0003 to match local connection rules. Neither task is device-verified; Mac compilation, Swift tests, SQL execution and the new TESTING checklist remain required. Original assignments are retained.

**Update 2026-10-17 (Codex, U3):** U3.4 standalone validator implemented: `python tools/validate_map.py` passes on the sample, and 9 Python regression tests pass on Windows. Usage: `tools/README.md`. CI integration remains pending under INF-2; Swift make checks need a Mac. Original task table retained below.

Supersedes the per-letter assignments above (struck through there). Everything else in Revision 2 (the product loop, streams 0-7, milestones, cut lines) still holds.
**Assumption:** about 24 hours of working time remain from "H+0", the moment everyone has read this. Shift the clock if that is wrong; the ORDER and the gates matter more than the hours.

## 1. The team and what each device can do

| | **U1** | **U2** | **U3** | **U4** |
|---|---|---|---|---|
| Computer | MacBook Pro | MacBook Air | Windows PC | Windows PC |
| Phone | iPhone 16 Pro Max (LiDAR) | iPhone Pro (LiDAR) | iPhone Pro (LiDAR) | regular iPhone (**no LiDAR**) |
| Can build/install the iOS app | yes | yes | **no** (needs a Mac, or sideloading, see INF-1) | **no** |
| Can run `make test` / `typecheck` | yes | yes | no locally (Swift package imports Apple `simd`); via CI or Live Share | no (same) |
| Lane | **Scan + relocalization lead; integration captain** | **Guidance, obstacles, app lead** | **Backend, web, tooling; second LiDAR phone** | **Field, QA, demo lead** |
| Old letters | A | B, part of C, part of D | part of C, part of D | part of D |

| Capability on the phone | U1 | U2 | U3 | U4 |
|---|---|---|---|---|
| LiDAR live scan + mesh | yes | yes | yes | **no** (camera only; app must degrade gracefully) |
| Obstacle detection (LiDAR depth) | yes | yes | yes | **no** |
| Navigator + relocalization (ARWorldMap) | yes | yes | yes | yes (to be verified, task U4.8) |
| Sign OCR (Vision) | yes | yes | yes | yes |
| Simulate mode, cloud UI, Multipeer | yes | yes | yes | yes |

## 2. What we have so far (evidence as of this commit)

| Area | State | Evidence |
|---|---|---|
| Build system, XcodeGen, Makefile, doctor, typecheck | DONE | ~~`make test` 50 pass; `make typecheck` OK (19 app files);~~ **Update 2026-10-17 (Claude):** `make test` 85 pass; `make typecheck` OK (22 app files + 1 UI test file); `make check` BUILD SUCCEEDED |
| Data model, storage, merge, validation (hostile maps, path-traversal-safe ids) | DONE, unit-tested | ModelTests |
| Routing (A*), follower, feedback rules, obstacle hysteresis, room-number parser | DONE, unit-tested | RoutingTests, FeedbackAndVisionTests |
| Bounding-box math, export size budget, pose simulator, end-to-end simulated walk | DONE, unit-tested | ScanAndSimulationTests |
| Supabase client + sync engine (mock server), Keychain session | DONE, unit-tested | CloudTests |
| `supabase/migrations/0001_init.sql` | WRITTEN, **never run** on a real project | – |
| App: shell, volunteer live scan view, navigator, Simulate mode, Share maps (Multipeer + Cloud + AirDrop export) | SCAFFOLD, type-checks, **UNVERIFIED ON DEVICE** | – |
| Docs: AGENTS, MODULES, WORKLOG, DECISIONS (D-001..D-018), SETUP, TESTING, WORKFLOW | DONE | – |
| **NOT built yet** | marker image asset + marker capture; multi-segment relocalization + rollover; extend-existing-map flow; off-route re-routing; SignReader wired to screens; open-`.waypointmap` handler; mesh export (USDZ/OBJ) + in-app 3D viewer; per-class mesh colouring; web viewer; CI workflow; `make ipa`; Rice Hall survey; demo script; voice destination | – |
| **Nobody has yet** | run the app on any phone; created the Supabase project; scanned a real hallway | – |

## 3. Phases, gates, and the critical path

| Phase | Hours | Goal | Gate at the end (go / fallback) |
|---|---|---|---|
| **P0 Setup & first light** | H+0 → 2 | App runs on every phone that can run it; Supabase project alive | **G1:** U1 and U2 phones run the app; Supabase says "Cloud ready" on at least one phone. Else: finish setup before anything else, cloud work continues offline. |
| **P1 Prove the risky parts** | H+2 → 7 | Live scan works; relocalization measured; Simulate cues tuned; RLS verified; Rice Hall surveyed | **G2 (relocalization):** ≥ 4 of 5 relocalizations succeed → continue. Else **marker fallback becomes mandatory** (U1.7 + U4.6 become top priority). |
| **P2 Core loop** | H+7 → 12 | Scan a real hallway, navigate it by sound with obstacle warnings; cloud round trip works | **G3:** scan → save → relocalize → guided walk to a tagged door works once on a real hallway. Else cut: cloud, OCR, mesh export (in that order of sacrifice, see section 8). |
| **P3 Integration & cloud** | H+12 → 16 | Two-phone flows: Multipeer, cloud upload/download, extend map; web plan view | **G4:** a map scanned on one phone is navigated on another. |
| **P4 Features & polish** | H+16 → 19 | OCR wired, mesh export + viewer, accessibility, off-route | Feature freeze at H+19. Anything unfinished is cut, not rushed. |
| **P5 Real-site rehearsal** | H+19 → 22 | Scan Rice Hall, three blindfolded dress rehearsals with escort | **G5:** one clean rehearsal. Else demo falls back to the best-tested shorter route. |
| **P6 Freeze & demo** | H+22 → 24 | Final builds, maps preloaded, devices charged, backup video | Demo. |

**Critical path (anything late here delays everything):** U1.1 → U1.4 → U1.5 → U1.6 (**G2**) → U1.9 (**G3**, joint real walk with U2) → U1.13 (Rice Hall scan) → U1.15 (freeze). Parallel but required: U3.1 (Supabase) before any cloud test; U4.2 (survey) before U1.13.

## 4. Work for each person

Task format: **ID — task** · phase · estimate · blocked by · **done when** (the check that proves it) · files. Record every finished task in `docs/WORKLOG.md` (what you ran, the result, and "UNVERIFIED ON DEVICE" for anything not tested on a phone).

### U1 — MacBook Pro + iPhone 16 Pro Max: Scan and relocalization lead, integration captain
Branch prefix `u1/`. Owns: `Waypoint/Capture`, `Waypoint/Relocalization`, `Waypoint/Scan`, core `Model/MapBuilder`, `Geometry`, `project.yml`, `Makefile`, merges to `main`.

| ID | Task | Phase | Est. | Blocked by | Done when |
|---|---|---|---|---|---|
| U1.1 | Signing + run on own phone: `docs/SETUP.md` §1-§4; run `sudo xcodebuild -runFirstLaunch` if `make doctor` warns | P0 | 0.75h | – | `DEVICE=<id> make run` launches the app, camera + local network permissions accepted. **Blocks everyone's device work.** |
| U1.2 | Branch hygiene: create `u1/..`, `u2/..`, `u3/..`, `u4/..` working branches; agree "only U1 merges to `main` after `make test && make typecheck && make check`" | P0 | 0.25h | – | rule written in `docs/WORKFLOW.md` (as an Update line) |
| INF-1 | `make ipa` target (archive + export an .ipa) and a SETUP.md section so U3/U4 can sideload without a Mac with their own Apple ID (third-party tools such as Sideloadly or AltStore; not verified by us, use only if cabling to a Mac is impossible). Alternative: U1/U2 cable-install onto U3/U4 phones | P0 | 1.5h | U1.1 | at least one of U3/U4 has the app running |
| U1.3 | Review U3's CI workflow (INF-2) and confirm the Xcode version on the runner can run `make test` and `typecheck` | P0 | 0.25h | INF-2 | CI green on a PR |
| U1.4 | TESTING 3.1 live scan: mesh overlay appears, HUD counters nonzero, box tracks the space. **Known risk:** ARView may take over the session delegate (counters stay 0) → fix by forwarding frames | P1 | 1.5h | U1.1 | screenshot/screen-record of live mesh + green box; counters change as you walk |
| U1.5 | TESTING 3.2-3.4: box margin buttons, tag Room/Door/Stairs, wait for "Mapping: mapped", Save; open the Files app → Waypoint → Maps and confirm `map.json` + `worldmap-seg1.arworldmap` exist | P1 | 1h | U1.4 | saved map lists on Home with expected node count |
| U1.6 | **TESTING 3.5 relocalization ×5** (kill app, relaunch, Navigate, stand at start); also once with changed lighting and once starting 3 m away. Fill a results table in the WORKLOG | P1 | 1.5h | U1.5 | table of 5+ trials with seconds-to-localize. **Gate G2.** |
| U1.7 | *(only if G2 fails, otherwise skip)* Marker fallback end to end: PNG from U4.6 → asset catalog group `WaypointMarkers` (add to `project.yml`) → volunteer mode detects the marker and stores `MarkerRef` (position/yaw in map frame) → navigator aligns via `mapToWorldTransform`. Verify yaw convention on device and update `GeometryTests` | P2 | 3h | U1.6, U4.6 | relocalizes at the marker in ≥ 4 of 5 trials |
| U1.8 | Multi-segment: assign a new `segmentId` every ~30 m while scanning (pure helper + tests in core), `Relocalizer` tries each segment's world map until one localizes | P2 | 2.5h | U1.6 | 2-segment map relocalizes in the second segment |
| U1.9 | Joint integration #1 with U2 (TESTING 3.6): scan a real hallway (your building), navigate it on U2's phone with headphones | P2/P3 | 1.5h | U1.6, U2.4 | walk reaches the tagged door guided by sound |
| U1.10 | Extend an existing map: load map → relocalize → `MapBuilder` links the first new breadcrumb to the nearest existing node (+ unit tests) | P3 | 2h | U1.8 | extended map has no disconnected island; test added |
| U1.11 | Review and merge window every ~2 h; keep `main` green; resolve conflicts; tag `demo-candidate-N` | all | ongoing | – | `main` builds at every merge |
| U1.12 | Per-anchor mesh colouring by `ARMeshClassification` (replace debug overlay) | P4 | 2h | U1.4 | floor/wall/door visibly different. **Cut first if behind.** |
| U1.13 | **Rice Hall scan** of the final route using U4's survey; tag every target room; upload to cloud (U2.8 verified path); copy bundle to every demo phone | P5 | 2h | U4.2, U1.8 | final map loads and relocalizes on U2's phone |
| U1.14 | Door suggestions from mesh classification (stretch) | P4 | 2h | U1.12 | suggested door chips appear while scanning |
| U1.15 | **Freeze:** tag `demo-freeze`, reinstall the final build on every phone (before the 7-day free-signing expiry), check each phone launches offline | P6 | 1h | G5 | each phone runs the freeze build |

### U2 — MacBook Air + iPhone Pro: Guidance, obstacles, app lead
Branch prefix `u2/`. Owns: `Waypoint/Guidance`, `Waypoint/Navigation`, `Waypoint/Vision`, `Waypoint/Sync`, `Waypoint/UI` (Navigator/accessibility), core `Routing`, `Guidance`, `Vision`.

| ID | Task | Phase | Est. | Blocked by | Done when |
|---|---|---|---|---|---|
| U2.1 | Signing + run on own phone (SETUP.md); `make test` and `make typecheck` on the Air; note build times | P0 | 1h | – | app runs; WORKLOG note |
| U2.2 | TESTING 2.1-2.6 with headphones in Simulate mode; write a "what feels wrong" list (cue timing, ping loudness/direction, haptic clarity, wording) | P1 | 1.5h | U2.1 | list in WORKLOG with at least 5 concrete items |
| U2.3 | Tune guidance: ping rate rises as you approach; distinct arrival chime; haptic pattern strengths; use U4.5's wording; add hysteresis to left/right announcements so borderline headings do not flicker (**+ unit tests** in `FeedbackPlanner`) | P1 | 3h | U2.2, U4.5 | `make test` passes with new tests; re-listen to a simulated walk and it sounds right |
| U2.4 | Navigator real-walk readiness: verify Navigator on a real saved map with U1 (joint, see U1.9) | P2 | 1.5h | U1.6 | same as U1.9 |
| U2.5 | Off-route detection and re-route (> 3 m from route → recompute from nearest node, say "Recalculating") + tests in `Routing` | P2 | 2h | – | test: walker leaves route and gets a new valid route |
| U2.6 | **Obstacle calibration** (TESTING 3.7) in a real corridor: check depth-map orientation with the phone held portrait, tune region/thresholds, switch min → low percentile, add a downward drop-off check; update `ObstacleClassifier`/`ObstacleDetector` + tests; record measured distances | P2 | 3h | U2.1 | caution fires at ~1.2 m and stop at ~0.6 m on a wall; no false alarms walking down a clear hallway |
| U2.7 | Wire `SignReader`: Navigator announces "Room 204 ahead" on confirmed reads; Volunteer shows a "Add label 204?" suggestion chip (human confirms). Use U4.3's photos/ground truth as parser test strings | P3 | 3h | U4.3 | reading a real door sign on the phone confirms the number within 3 s |
| U2.8 | Multipeer 2-phone test (TESTING 2.7) with U1 or U3's phone; Cloud UI test (2.9) once U3.1 is done; fix what breaks | P3 | 2h | U3.1 | map moves phone → phone and phone → cloud → phone |
| U2.9 | "Open `.waypointmap`" handler (Files/AirDrop import) that shows the SAME approval alert before importing (D-012) | P4 | 1.5h | – | AirDropped file prompts, then imports |
| U2.10 | Accessibility pass: VoiceOver labels, one giant Start target, haptic confirmation on taps, Dynamic Type, no screen needed to start navigation. Use the `design:accessibility-review` skill | P4 | 2h | – | whole flow usable with VoiceOver on and eyes closed |
| U2.11 | Voice destination (`SFSpeechRecognizer`) — stretch, cut if behind | P4 | 2h | U2.10 | "Room 204" spoken → navigation starts |
| U2.12 | Dress rehearsals with U4 directing (P5): timing of cues, volume, stuck points; fix cue bugs only | P5 | 2h | U1.13 | 3 rehearsals logged |
| U2.13 | Freeze: final build on own phone, offline check | P6 | 0.5h | G5 | – |

### U3 — Windows PC + iPhone Pro: Backend, web and tooling lead; second LiDAR phone
Branch prefix `u3/`. Owns: `supabase/`, `web/` (new), `tools/` (new), `.github/` (new), core `Cloud/`, `Waypoint/Cloud`. Cannot build iOS; Swift changes happen via **Live Share on U1's or U2's Mac** (the host builds), or as small PRs the Mac owners compile.
Windows setup (U3.2): Git, Node 20 and/or Python 3, VS Code + Live Share. `make` is not available on Windows; use `npm`/`python` scripts documented in each tool's README.

| ID | Task | Phase | Est. | Blocked by | Done when |
|---|---|---|---|---|---|
| U3.1 | **Create the Supabase project** (free), enable Anonymous Sign-Ins, run `supabase/migrations/0001_init.sql`, confirm tables, buckets (`worldmaps`, `meshes`) and policies exist. Share URL + **anon** key privately (team chat), never commit; never share the `service_role` key | P0 | 1h | – | "Cloud ready" on a phone; **Gate G1 (cloud half)** |
| U3.2 | Windows dev setup (Git, Node/Python, VS Code, Live Share); clone; open the docs | P0 | 0.5h | – | can run a tools script |
| INF-2 | `.github/workflows/ci.yml`: on push/PR run `make test` and `make typecheck` on a macOS runner (check the repo's Actions minutes and Xcode version; macOS minutes cost more) | P0 | 1h | – | green check on a PR; Windows teammates see results without a Mac |
| U3.3 | **RLS test suite** in `tools/supabase-tests/` (Node or Python, same REST calls as the app). Cases: user A inserts own row; user B cannot update/delete A's row; private row invisible to B; shared row visible to B; storage upload into another user's folder is denied; file > 50 MB rejected; bad paths rejected; unauthenticated (no JWT) denied. Any SQL fix goes into a NEW file `0002_*.sql` (do not edit the already-run `0001`) | P1 | 3h | U3.1 | script prints PASS/FAIL per case; results in WORKLOG |
| U3.4 | `tools/validate_map.py`: independent re-implementation of `MapBundle.validate()` and `SegmentID` that runs on `Samples/*.json`; run in CI. Catches contract drift between Swift and everything else | P1 | 1.5h | – | passes on the sample; fails on hand-made hostile files |
| U3.5 | Ops scripts: seed the sample map as a shared row; `wake_project` ping; export backup of tables/storage listing; weekly keep-alive GitHub Action (free projects pause after ~1 week idle) | P2 | 1.5h | U3.1 | scripts documented in `tools/README.md` |
| U3.6 | Agree export formats with U1/U2: USDZ for the app, OBJ or GLB for the web; ≤ 40 MB; paths `meshes/<owner>/<map>/<scan>.<ext>`; DB `scans` row. Write it into Architecture.md §10.2 as an Update line | P2 | 1h | – | decision recorded |
| U3.7 | **Web viewer v1** `web/` (static HTML + JS, no build tooling): anonymous sign-in, list shared maps, draw a plan view (nodes, edges, labels, stairs highlighted) on a canvas, click a destination → show the A* route. Port the router to JS and check it against shared vectors in `Samples/route-vectors.json` (U3 adds them; Swift test reads the same file) | P3 | 5h | U3.1 | page on a laptop shows the Rice Hall map and a route; Swift and JS agree on test vectors |
| U3.8 | **Pair on mesh export** (Live Share on a Mac host): `MeshExporter` crops `ARMeshAnchor`s to the `OrientedBox`, writes USDZ within `ExportBudget`, then `SyncEngine.pushScan` uploads to `meshes` and inserts a `scans` row (core part + tests) | P4 | 4h | U1.4, U3.6 | exported file opens in Quick Look on the phone; row appears in the dashboard |
| U3.9 | Web 3D preview of an uploaded scan (three.js + OBJ/GLB) — stretch | P4 | 3h | U3.8 | scan spins in the browser |
| U3.10 | Field day: second LiDAR phone for the two-phone tests and as the second scanner; watch Supabase quotas/pausing | P5 | 1h | INF-1 | – |
| U3.11 | Pre-demo: wake project, backup export, clear test rows, verify the anon key in each phone's `Local.xcconfig` | P6 | 0.5h | – | – |

### U4 — Windows PC + regular iPhone (no LiDAR): Field, QA and demo lead
Branch prefix `u4/`. Owns: `docs/field/` (new), demo materials, `Samples/` additions, QA reports. Needs no Swift. The regular iPhone also tests the "no LiDAR" paths and cross-device relocalization.

| ID | Task | Phase | Est. | Blocked by | Done when |
|---|---|---|---|---|---|
| U4.1 | Read AGENTS.md, ROADMAP, TESTING; set up Git + VS Code; get the app installed on your phone (INF-1) | P0 | 0.5h | INF-1 | app launches on the regular iPhone |
| U4.2 | **Rice Hall recon walk:** primary + backup destination rooms, route length (paces → metres), stairs/elevators, door types, glass walls, lighting, long identical corridors (relocalization risk), sign styles/heights, Wi-Fi quality, crowding times. Photos + a sketched floor plan → `docs/field/rice-hall.md` | P0/P1 | 2h | – | file committed; feeds U1.13 and risk decisions |
| U4.3 | Sign dataset: 40+ photos of real room signs at 1-3 m, mixed angles/lighting; `docs/field/signs.csv` with ground-truth text; no faces | P1 | 1.5h | U4.2 | files committed; U2.7 uses them |
| U4.4 | Demo script + **safety plan**: escort walks beside the blindfolded person, consent, a stop word, route cleared of obstacles, no stairs, headphone/volume check, who is on the phone, 2-minute spoken pitch, backup demo → `docs/field/demo-script.md` | P1 | 2h | – | reviewed by the team |
| U4.5 | Spoken cue wording and onboarding script (what the user hears first, "one tap = left, two taps = right"); if you can reach a blind or low-vision person (campus accessibility resources or a student group), get their feedback respectfully and note it → `docs/field/cues.md` | P2 | 2h | – | handed to U2.3 |
| U4.6 | Marker: generate a high-contrast marker image, print at known size (measure the real width), choose a wall spot, measure its position from the scan origin with U1. Hand the PNG to U1.7 | P2 | 1.5h | – | printed marker + measurements in `docs/field/marker.md` |
| U4.7 | QA pass #1 on the regular iPhone: launch, permissions, sample map, Simulate mode, Share maps screen; confirm **graceful behaviour without LiDAR** (volunteer view shows camera without crashing, no obstacle detection). Bugs → `docs/field/bugs.md` (ID, steps, expected, actual, phone) | P2 | 2h | U4.1 | bug list triaged by U1 |
| U4.8 | **Cross-device relocalization:** Navigator on the regular iPhone using a map U1 scanned on the Pro Max. Result decides whether this phone can be the demo's "blind user" phone | P3 | 1.5h | U1.6 | pass/fail table |
| U4.9 | Run TESTING level-2/3 rows as assigned; log results (row, phone, iOS, pass/fail, console excerpt) | P3-P5 | ongoing | – | WORKLOG entries |
| U4.10 | Pitch deck, Devpost/README text, one-page architecture diagram (use real numbers) | P4 | 3h | – | draft reviewed |
| U4.11 | Record backup demo footage (Simulate walk + a real walk) | P4/P5 | 2h | U2.3 | video file ready |
| U4.12 | **Direct the dress rehearsals:** 3 full runs with blindfolded teammates and an escort; time each; log what went wrong | P5 | 2h | U1.13 | 3 logged runs; **Gate G5** |
| U4.13 | Run-of-show, battery/charger checklist, printed signs/markers, fallback script | P6 | 1h | – | checklist ticked at the venue |

## 5. Dependencies at a glance

```
U1.1 ─┬─ U1.4 ─ U1.5 ─ U1.6 ──(G2)── U1.7 (if needed) ─┐
      │                         └─ U1.8 ─ U1.10        ├─ U1.9 ─ (G3) ─ U1.13 ─ U1.15
U2.1 ─┴─ U2.2 ─ U2.3 ─────────────────────────────────┘     ▲
U3.1 ── U3.3, U2.8, U3.5, U3.7 ── U3.8 (needs U1.4)         │
U4.2 ── U4.3 ── U2.7                U4.2 ──────────────────┘
U4.5 ── U2.3        U4.6 ── U1.7        INF-1 ── U3/U4 devices
```

## 6. Branches, merging, ownership

- Each person works only on their branch prefix (`u1/…`). Keep commits small and push often.
- **Only U1 merges to `main`**, in windows about every 2 hours, after `make test && make typecheck && make check`. CI (INF-2) gives U3/U4 the same result without a Mac.
- Directory ownership is in the section headers above. Edits outside your directories: keep them small, say so in the WORKLOG. `project.yml` and `Makefile` belong to U1.
- `docs/WORKLOG.md`: everyone appends at the top. Other `.md` files: strike through the old text and add a labelled Update (AGENTS.md rule 11).
- Live Share with a Windows teammate: the Mac owner hosts on their own branch; the guest edits there; the host builds and tests.

## 7. Rhythm

- **Check-in every ~3 hours** (5 minutes, in chat): each person posts `done / doing / blocked / need from whom`.
- **Gate reviews** at G1-G5: the whole team decides go or fallback; the decision is written in the WORKLOG.
- **Bugs:** found on a phone → `docs/field/bugs.md` (U4 maintains); U1 triages; the owner of the area fixes.

## 8. Cut order if time runs short (unchanged principle, now with owners)

1. U1.14, U3.9, U2.11, U1.12 (stretch visuals and voice)
2. U3.8 mesh export and 3D preview; U3.7 web viewer (keep a minimal plan view if possible)
3. U2.7 OCR wiring (labels typed by the volunteer instead)
4. Cloud sync (U2.8 cloud half) → AirDrop/Multipeer export, already built
5. U1.10 extend-map flow
**Never cut:** U1.4-U1.6 (scan + relocalization), U1.9/U1.13 (real walk), U2.3/U2.6 (cues and obstacles), U4.4/U4.12 (safety plan and rehearsals).

## 9. Open questions for the team (answer in chat, then record under "Update")
1. Can U3/U4 be physically with a Mac for cable installs, or do we need the sideloading path (INF-1)? Free provisioning may limit how many devices and apps one Apple ID can sign; check at install time.
2. Which GitHub plan runs the repo's CI (macOS runner minutes)?
3. Is the regular iPhone (U4) allowed to be the demo's navigator phone if U4.8 passes? It would leave the three LiDAR phones free for scanning.
4. Public ("share with everyone") or team-only sharing for maps? (Architecture §9, item 7)

## Update 2026-10-17 — accessibility requirements added to the plan (D-022)

New tasks, in addition to the Revision 3 tables above (owners follow the existing lanes):
| ID | Owner | Task | Done when |
|---|---|---|---|
| A11Y-1 | U1 | On the Pro Max run checks A1-A3 (docs/TESTING.md, "Accessibility checks on a real phone") and confirm the posture signs/axes; report anything swapped | pitch/roll read as described |
| A11Y-2 | U2 | A4 + A5 with headphones: posture coaching feels right and the beacon is in the correct ear | both pass; tune thresholds (`PostureMonitor`) and haptic strength |
| A11Y-3 | U2 + U1 | A6 in a real corridor: obstacle sentences and timing; calibrate `ObstacleDetector` corridor/band and `ObstacleClassifier` distances; side obstacles; low objects | walking into a wall/chair/trash can is announced by name before contact |
| A11Y-4 | U4 | Review every sentence in `SpokenPhrases.swift` / `PhonePosture.swift` with a blind or low-vision person if reachable; list wording changes (they are one file each, with tests) | list handed to U2 |
| A11Y-5 | U3 | Run `make selftest-e2e` on every teammate's phone; paste the `vision.labels.*` lines so the label mapper can be tuned for all models | lines in WORKLOG |
| A11Y-6 | U2 | Stairs-down / ledge detection (a downward depth check) and temporal voting for object names (needs A11Y-3 data) | stretch |
Cut line: A11Y-1/2/3 are part of the never-cut "guided walk with obstacles" path; A11Y-6 is stretch.

## Update 2026-10-17 — status snapshot against Revision 3 (Claude, evidence = WORKLOG + a test run; the tables above have no done markers)

| Phase / task | Evidence | State |
|---|---|---|
| P0 U1.1 signing + run on the Pro Max | WORKLOG 16:20, 17:10 | DONE |
| P0 other phones (U2/U3/U4) | none recorded | UNKNOWN |
| P0 Supabase project (U3.1) | U3 ran migrations 0002/0003 and SQL tests in the dashboard (user-reported) | project exists; "Cloud ready" on a phone not recorded (E2E cloud step skipped) |
| INF-1 `make ipa`, INF-2 CI workflow | no `ipa` target, no `.github/` | NOT STARTED |
| U3.4 map validator | `tools/validate_map.py`, 9 Python tests pass | DONE |
| U3.3 RLS suite (`tools/supabase-tests/`) | only `supabase/tests/*.sql` (canonical maps) exist | PARTIAL; the 0001 policy cases are not covered |
| U1.4-U1.6 live scan, save, relocalization x5 (**Gate G2**) | no real-hallway scan or trial table in the WORKLOG | NOT DONE, and it is the critical path |
| U2.2/U2.3/U2.6 guidance + obstacle tuning on a phone | simulated-walk E2E 20/0/1 and UI tests 7/7 on the Pro Max; real corridor calibration not done | PARTIAL (software side done, calibration open) |
| A11Y-1..A11Y-6 | code + tests done; posture axes, beacon ear, real obstacle hits unverified | OPEN |
| U1.10 extend an existing map | built (MapBuilder + CaptureController + VolunteerView + migration 0003), tests pass | DONE in code; UNVERIFIED ON DEVICE |
| U1.8 multi-segment relocalization, U2.5 re-routing, U2.7 OCR wiring, U2.9 `.waypointmap` handler | ~~not found in code/WORKLOG~~ ~~NOT STARTED~~ **Update 2026-10-17 (Claude, 21:45):** U2.5 re-routing DONE in code (Anmol's off-route re-route on `navigation-overhaul` + blocked-path detour + route memory); U2.7 OCR PARTLY (SignReader fed from NavigationController, confirmed signs are spoken, sign-vs-position check is log-only); U1.8 and U2.9 still NOT STARTED | see the 21:45 snapshot below |
| U3.7 web viewer, U3.8 mesh export, U3.5 ops scripts | no `web/`, no `MeshExporter` | NOT STARTED |
| U4.2-U4.6, U4.9-U4.13 field/QA/demo | no `docs/field/` | NOT STARTED (or not in the repo) |
| New Scanner/Navigator UI | ~~branch `app-ui-workflows` (neehamikki), 1 commit, one conflict in `RootView.swift`, not merged~~ **Update 2026-10-17 (Claude):** merged into `main` (dd38866); behind a default-off "New interface" switch | ~~PENDING merge decision~~ MERGED; New-UI Level-4 checks in TESTING.md still unrun |

Gate status: G1 partial; **G2 untested**; G3-G5 not reached. Highest-value next step: the real-phone U1.4-U1.6 walk.
**Update 2026-10-17 (Claude, 21:45):** still true for G2 (no trial table exists), but see the new snapshot below: a real scan now exists on U1's phone.


## Update 2026-10-17 21:45 — status snapshot 2 and what is next for U1 (Claude; evidence = branches fetched at 21:40, WORKLOG, files read off U1's connected iPhone, on-phone test runs)

**Branches (cross-referenced).**

| Branch | State | Action |
|---|---|---|
| `main` (dd38866) | has `U3`, `app-ui-workflows`, route memory, map format 2 | – |
| `U3`, `app-ui-workflows` | fully inside `main`; no new commits | can be deleted after the team agrees |
| `fix/guidance-voice` (e1c7a1a, pushed) | `main` + `navigation-overhaul` up to 556c0f0 + the 4 guidance fixes + map format 3; `make test` 217 pass, typecheck, `make check`, E2E 20/0/1, UI tests 7/7, simulated walk PASS on U1's phone | review + merge (U1 is merge captain, U1.11) |
| `navigation-overhaul` (Anmol Thapa) | 12 commits ahead of main; its last 2 (4158bc0 speech queue "only safety interrupts"; c5ba14f off-main-thread scan loading) are NOT in `fix/guidance-voice` and conflict in `NavigationController.swift` | merge them into `fix/guidance-voice` first, re-run the phone tests |

**On U1's phone right now (read via `devicectl`, installed build = `fix/guidance-voice` + classic-UI fix).** Two maps: the SAMPLE and a REAL scan "Rice Hall · Floor 4" (17 nodes, rooms 409/410/411, about 8 m long, ONE segment, 17.8 MB world map, saved in format 2). It passes `tools/validate_map.py`. A `route-memory.json` with one cached 12.3 m route sits next to it, so a navigation on the real map ran and persisted memory. This is the first real data: U1.4/U1.5 are effectively done. Nothing records U1.6 yet.

**Done since the earlier snapshot:** voice = Siri voice (13 installed on the phone; "Nicky" compact chosen), opening briefing, arrival-only at the destination, sensor-based warnings, off-route + blocked-path re-routing, route memory, map format versioning with a spec per version. All verified on the phone only in SIMULATION; real LiDAR / real hallway / real door still unverified.

**Next for U1, in order**
1. **U1.6 / Gate G2 (critical path, needs you and the hallway):** with the Floor 4 scan, kill the app, relaunch, Navigate to Room 410 from the scan's start; repeat 5 times, once with different lighting, once starting 3 m away. Record seconds-to-localize per trial in a WORKLOG table. If fewer than 4 of 5 localize, U1.7 (marker fallback) becomes top priority.
2. **Merge captain (U1.11):** merge the 2 newer `navigation-overhaul` commits into `fix/guidance-voice`, rerun `make test`, `typecheck`, `check`, `uitest`, then merge to `main`.
3. **Rescan with the current build** (it has loop closure and room floor areas; the existing scan is an 8 m chain from before). Walk a longer route (30 m+) so U1.8 multi-segment has something to prove, tag rooms.
4. **Listen test (needs ears):** `DEVICE=<id> make selftest-sim` with headphones: is the Siri voice acceptable, is the opening briefing clear and short enough? An enhanced/premium Siri voice may sound better than the compact one (Settings > Accessibility > Spoken Content > Voices).
5. **U1.8** multi-segment relocalization (not started), then **U1.9** joint walk with U2 on the real map.
6. Cheap housekeeping: U1.2 branch rule, INF-1 `make ipa`, INF-2 CI (the GitHub docs-check Action has run on the main push; check its result in the Actions tab).

**Not on U1's list but open for the team:** mesh export + 3D viewer (U3.8, nothing built), web viewer (U3.7), `.waypointmap` open handler (U2.9), field survey and demo script (U4), real-LiDAR calibration of obstacles and the new side-clearance hints (U2.6).


**Update 2026-10-18 (Claude, confirmed by Sachin): who is who.** U1 = Sachin Khanal · U2 = Anmol Thapa (branch `navigation-overhaul`) · U3 = Rishya (GitHub `rishyam1`; branch `U3`, `supabase/`, `tools/`, `web/`) · U4 = Neeha (GitHub `neehamikki`; branch `app-ui-workflows`, the new Scanner/Navigator UI). Git history uses the handles; the docs use U1-U4.


## Update 2026-10-18 — snapshot 3: U1 status (Claude, for Sachin; evidence = branches fetched, WORKLOG, phone runs)

| U1 task | State now |
|---|---|
| U1.1 signing + run on phone | DONE |
| U1.2 branch hygiene | DONE (rule written in `docs/WORKFLOW.md`, 2026-10-18) |
| U1.4 live scan, U1.5 save | DONE on the phone: 3 real scans saved with a 3D model each; one was a 27.5 MB scan file |
| U1.6 relocalization x5 (**Gate G2**) | NOT RUN. Needs Sachin + the phone in a hallway; it is the biggest unknown |
| U1.7 marker fallback | not started (only if G2 fails) |
| U1.8 multi-segment relocalization | NOT STARTED. Needs U2's relocalization changes (branch `navigation-overhaul`, not yet in `main`) first |
| U1.9 joint walk with U2 | blocked on U2's merge |
| U1.10 extend an existing map | built, first screen verified on the phone; real recording/attach UNVERIFIED (needs a physical test) |
| U1.11 merge captain | ongoing: `main` = `fix/format-alignment-security`; `fix/*` branches deleted after merge |
| U1.12 / U1.14 mesh colouring, door suggestions | not started (cut first) |
| U1.13 Rice Hall scan | blocked on U4's survey (U4.2) |
| U1.15 freeze | later |
| NEW: size policy | scans over the 50 MB cloud limit are saved on the phone only (`SharePolicy`, `MapStore.saveLocalScan`); see WORKLOG 2026-10-18 |
| NEW: finish gating | Finish/Save still requires ARKit `mapped` plus one labelled place; no change yet (decision pending) |

**Update 2026-10-18 (Codex, U3 integration):** integrate-u3 resolves U3/main conflicts while retaining main keyframes, optional manifests, USDZ and local-save policy, and adding OBJ payload storage/cloud. Python 22 + browser 62 checks pass. Native make test/typecheck unavailable on Windows: Mac validation required before main push. First-floor demo excluded. Incoming migrations are 0006/0007/0008; earlier U3 numbering in historical notes is superseded.


**Update 2026-10-18 (Codex, audit integration):** Also retain the incoming audit notes below.

**Update 2026-10-18 (Claude, audit):** a security/privacy audit was done; findings and open items are in `docs/SECURITY.md` (cloud abuse limits S-1, personal data in the public repo S-2, Files-app exposure S-3 are the ones to act on before a demo).


**Update 2026-10-18 (Codex, stairs/navigation integration):** Preserve incoming branch notes below.

## NEW 2026-10-18 — Anmol's field test of `navigation-overhaul` @ `fecc146`: next session's queue

Full detail (with the knobs and the leads) is the WORKLOG entry
"Field test of the merged branch: overall good, 8 findings for tomorrow" at the top of `docs/WORKLOG.md`.
Overall verdict was positive; this is the fix list, not a revert list.

Do first — these decide whether a blind user can finish a route:

| # | Finding | Owner | Note |
|---|---|---|---|
| ~~F-1~~ | ~~CRITICAL: contradicting directions (speech says left, arrow says right; cues out of order)~~ **Update 2026-10-18 (Claude):** MOSTLY FIXED in code, UNVERIFIED ON DEVICE. The recorded walk showed the real problem was bigger: NO turn was spoken at all, because a caution was `.critical` (interrupts) and an interrupt discarded the queued turn. STILL OPEN: when an avoidance ("Slightly left") disagrees with the route ("Turn right"), nothing relates the two. See WORKLOG. | B | re-walk the same route |
| ~~F-5~~ | ~~MAJOR regression: obstacle says only "Stop", no way through~~ **Update 2026-10-18 (Claude):** FIXED in code, UNVERIFIED ON DEVICE. Not the suppression I guessed at: the advice was queued behind the stop line and dropped by `Speaker.maxQueuedAge = 2.0`. Also added "Back up slowly." for when no side is usable. See WORKLOG. | B | needs a walk to confirm |
| ~~F-7~~ | ~~BIG: the direction is sometimes never spoken at all, usually under higher-priority traffic~~ **Update 2026-10-18 (Claude):** SAME ROOT CAUSE as F-5; fixed by raising `maxQueuedAge` to 4.5 s. UNVERIFIED ON DEVICE. The planner still marks a line "announced" when it generates it rather than when it is spoken - the remaining structural weakness if this recurs. | B | needs a walk to confirm |

Then:

| # | Finding | Owner | Note |
|---|---|---|---|
| F-6 | repetition without spamming; priority vs. freshness fight while moving | B | test more before changing `Speaker`/`SpeechGate` |
| F-3 | active-path / arrival radius too tight (a door point sat inside the shut door) | B | `ArrivalRadius` door = 1.2 m is the tightest |
| F-4 | relocalization wants specific viewpoints and never says "pan slowly, walk around" | A | the coaching TODO already in `Relocalizer.swift` |
| F-8 | QoL: starting instructions for the blind user at the top of a walk | B | |
| F-2 | preference: routes follow the volunteer's breadcrumbs, not the shorter mapped way | A | the real fix is floor-grid routing over the mesh (designed, not started) |

Also still open from the same session, already diagnosed with file:line in the WORKLOG: the 15 s save timeout
reported as a failure, the 60 s "no 3D model" stopwatch, the slow USDZ export, the export reading paused-session
Metal buffers, `CoverageTracker`'s absolute 2 m grid, and the loop-closure threshold mismatch (builder joins at
1.0 m in 3D, the health check flags at 1.5 m in 2D, so the "check before sharing" warning cannot be cleared).

Idea parked (Anmol): make the mesh triangles much coarser — nothing downstream needs 3.5 M of them. Note that
decimating harder alone will NOT speed up the export, because the cost is paid in `MeshExporter.extract` before any
decimation; the fix is snapping vertices to a grid while reading. Also worth revisiting that mesh detail is currently
set by `ExportBudget.defaultBudgetBytes = 40_000_000`, which is the Supabase free-tier file limit — a hosting
constraint standing in for a quality decision.
