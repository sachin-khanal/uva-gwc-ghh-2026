# Testing — what is proven, and the device test plan

**Update 2026-10-18 (Codex, comprehensive live QA):** Real cloud/browser verification is now recorded in `docs/VIEWER_QA_2026-10-18.md`, with reproducible `tools/test_live_viewer.mjs` (23 PASS). Five transactional SQL suites PASS; two saved deployment regressions FAIL: schema-4 compatibility and unpublished-mesh update bypass. Deterministic browser suites 74/74 + 24/24 PASS; Node 73 PASS / 2 browser skips; Swift 349 PASS; typecheck/full unsigned build PASS; Python 22 PASS; hooks 15 PASS. Hardware and Safari remain unverified. Do not infer an all-green backend from the passing viewer tests.

**Update 2026-10-18 (Codex, viewer completion):** From `feature/web-viewer-integration`, run `node web/test-web.mjs` (73 PASS, 2 browser-only SKIP), then `python3 -B web/serve.py --port 8041` and open `/web/tests.html` (74/74 PASS) and `/web/ui-tests.html` (24/24 PASS). Verified in fresh headless Chrome profiles with software WebGL, including schema 4, hostile OBJ bounds/indices, truncated downloads, route/walkthrough controls, progress, re-opening cache and changed-manifest revalidation. Native `make test` 349/349 PASS; `make typecheck` PASS (64 app files, 1 UI file; existing concurrency warnings). Live Supabase and real LiDAR visual fidelity were not tested in this session; native features remain UNVERIFIED ON DEVICE.

## Update 2026-10-17 (Codex) — existing-building extension checks (pending)

First run `make test` and `make typecheck` on a Mac (new MapExtensionTests included).
In Supabase, apply `0003_extension_connections.sql` after 0002, then run both
`supabase/tests/extension_connections.sql` and `supabase/tests/canonical_maps.sql`.
Expected: success, with PASS notices, and no persistent fixture data. These new
~~checks are NOT yet verified in this Windows session.~~
**Update 2026-10-17 (Claude):** on a Mac, `make test` (85 tests incl. the 3 MapExtensionTests) and `make typecheck` pass. Migrations 0001-0003 applied in order and BOTH SQL test files printed PASS (fixtures rolled back) on a throwaway local Postgres 17 container with a STUBBED `storage` schema; function grants checked as `anon`/`authenticated`. U3 separately reported the same SQL passing in the Supabase dashboard. The device checklist below is still UNVERIFIED ON DEVICE.

On a LiDAR phone, with an escort for navigation checks:

1. Scan and save a new building; note its ID, nodes and segment. Publish it.
2. Select that building under Scan, choose its saved scan area, and start there.
   Before relocalization/explicit attachment, node count must stay unchanged and
   tagging/save must be disabled. Missing world-map bytes must show an error.
3. After normal tracking returns, stand in a known corridor and tap begin extension.
   More than 2 m from an old corridor/junction (or on a different floor) must reject
   attachment without changing the graph. At a known corridor, one new breadcrumb
   connects to the closest corridor/junction; existing rooms/edges remain intact.
4. Walk into new space, tag a room, save. Same building ID/name, new unique segment,
   old scan files unchanged. Save stops recording. Cancel before save must leave
   the stored map unchanged. A tracking interruption must pause tagging/recording.
5. Publish the extension. On a second phone, refresh and download/import: one shared
   building entry, original and new rooms present, scan files from both contributors
   download. Route to the new room must connect through the old corridor. Re-open
   the building and relocalize from each saved scan area.

All AR alignment, tagging, save, audio and cross-phone behavior: UNVERIFIED ON DEVICE.

Three levels. Always run level 1 before handing off; levels 2-3 are for people with a phone.

## Level 1 — automated, no phone (`make test`, `make typecheck`, `make check`)

`make test` runs ~~45~~ **Update 2026-10-17 (Claude):** 85 XCTest cases in `Package/WaypointCore/Tests/` in about a second. They prove:
data model + JSON + merge + validation (hostile maps), routing (A*, stairs), bearings, the feedback rules,
obstacle hysteresis, room-number parsing, the scan bounding box, export budget, the simulated walker
(an END-TO-END walk to Room 204 that must end in "You have arrived"), and the whole Supabase client
(request shapes, sign-in/refresh/401 retry, push order, hostile downloads) against a MOCK server.
`make typecheck` / `make check` prove the iOS app compiles. NONE of this proves AR/audio/haptics/cloud
behave correctly on real hardware or against a real Supabase project.

## Level 2 — on a phone, but no scan needed (any iPhone; headphones for audio)

Run after SETUP.md §3 (`DEVICE=<id> make run`). Owner B/D. Mark each result in docs/WORKLOG.md.

| # | Check | Pass looks like |
|---|---|---|
| 2.1 | App launches; Camera + Local Network prompts appear; ~~Home shows "1 map(s)" (seeded sample)~~ **Update 2026-10-18:** there is no seeded sample map any more, a fresh install has NO maps until you scan or download one | no crash, prompts answered |
| 2.2 | Navigate -> pick a scanned map -> "Simulate walk to <a place>" (~~sample map, Room 204~~ **Update 2026-10-18:** use one of your own scans) | status "Simulating walk"; spoken "Navigating to Room 204…", then "Continue straight." |
| 2.3 | Wear headphones; listen during 2.2 | a ping that sits ahead/centre while walking, swings to the RIGHT during the last leg |
| 2.4 | Same run: haptics | right turn into Room 204 = two sharp taps; arrival = rising pattern |
| 2.5 | "Inject obstacle" toggle during a simulation | immediate "Stop. Obstacle ahead." + long buzz; ping goes silent; toggling off resumes |
| 2.6 | "Simulate, starting facing the wrong way" | hears "Turn around." first |
| 2.7 | Share maps with two phones nearby | "Connect to <phone>?" alert on the other phone; Send -> "Import this map?" alert; map appears after Import |
| 2.8 | Share maps -> Export (AirDrop) | share sheet opens with a `.waypointmap` file |
| 2.9 | Cloud (needs Supabase set up, see SETUP.md) | status "Cloud ready"; Upload then Refresh shows the map; a second phone can Download the shared one after an Import tap |

## Level 3 — Pro iPhone with LiDAR in a real hallway (owner A/C)

| # | Check | Pass looks like |
|---|---|---|
| 3.1 | Scan a building -> Start scanning | mesh overlay grows over the camera as you walk; green box appears and tracks the space; HUD shows triangles + box size |
| 3.2 | Box margin +/- | box grows/shrinks immediately |
| 3.3 | Tag Room / Door / Stairs while walking | node count rises; nothing crashes |
| 3.4 | Walk until "Mapping: mapped" -> Save map | "Saved N nodes"; map listed on Home |
| 3.5 | **Relocalization:** kill the app, relaunch, Navigate on the saved map, stand where you started | status reaches "Navigating" within ~30 s, in >= 4 of 5 tries. If not: marker fallback (docs/ROADMAP.md stream 2) |
| 3.6 | Walk the route with headphones | ping direction matches reality; turns announced at the right places |
| 3.7 | Walk toward a wall / a person | caution at ~1.2 m, stop at ~0.6 m (tune thresholds in ObstacleClassifier/Detector) |
| 3.8 | Point the camera at a door sign | (SignReader is not wired into a screen yet) check the console for "confirmed room number" once wired |
| 3.9 | Dress rehearsal | blindfolded teammate + escort reaches the target room |

## Reading logs from the phone

`DEVICE=<id> make launch` streams `os.Logger` output (subsystem ~~`edu.virginia.waypoint`~~ **Update 2026-10-17:** `io.github.sachin-khanal.waypoint`, categories:
app, capture, reloc, nav, guidance, vision, sync). Include relevant lines when reporting a bug.

**Update 2026-10-17 (found by testing on a phone):** ~~`make launch` streams `os.Logger` output~~ was wrong: `devicectl --console` captures only stdout/stderr, not the system log, so nothing appeared. `Log.<area>.info/error` (Waypoint/App/Log.swift) now ALSO writes each line to stderr as `[category] LEVEL message`, which is what `make launch` and the self-tests show. The system log is still written for Console.app.

## Headless tests on the phone (no tapping, no screen needed)  — added 2026-10-17

The phone must be **plugged in and UNLOCKED** (set Auto-Lock to Never while testing), with the volume up: the tests really play audio and speech.

| Command | What it does | Pass looks like |
|---|---|---|
| `DEVICE=<id> make selftest-sim` | launches with `-autoSimulate "Room 204"` (override: `ROOM="Room 206"`): runs the simulated walk, logs every instruction, spoken cue, haptic and beacon direction | ends with `SELFTEST PASS` and exit code 0. Exit 1 = timeout, exit 2 = no map has that destination, `Locked` error = unlock the phone |
| `DEVICE=<id> make selftest-scan` | launches with `-autoScan YES`: starts scanning immediately and prints `scan: tracking | mapping | nodes | meshAnchors | triangles | box` once per second | walk with the phone; `triangles` and `box` should grow. Ctrl-C to stop. Stuck at `meshAnchors=0` = the AR view is not sharing the session (known risk, U1.4) ~~|~~ **Update 2026-10-17:** that cause is ruled out (see "UI tests" below: frames reach our code). `meshAnchors=0` now means the camera is not looking at textured surfaces (aim at a room, not a desk/ceiling) or the phone has no LiDAR |

What these CANNOT check: how the audio sounds, how the haptics feel, what the mesh looks like. A person must judge those. Reference run (2026-10-17, iPhone 16 Pro Max): turn right at bearing 57 deg fired `haptic: turnRight` + `say: Turn right.`, beacon local x=+1.5 (to the right), arrival spoke and fired `haptic: arrived`, `SELFTEST PASS`.

## Accessibility checks on a real phone — added 2026-10-17
**Update 2026-10-17 (22:15):** the automated half is now VERIFIED on the phone (UI tests 7/7, E2E 20/0/1). Handy for helpers: in Simulate mode the screen has "Pause walker", "Inject obstacle", an obstacle-type menu and a phone-held menu, and shows the sentences just spoken (`nav.recentSpeech`).

Automated on the phone (`make selftest-e2e`, `make uitest`): the posture maths, every sentence (printed as `[e2e] INFO phrase.*`), the simulated walk now includes briefing / countdown / landmark phrases, picking an obstacle type changes the spoken sentence, and tilting the simulated phone makes the coach speak and later say "Phone position is good" (UI tests `testObstacleIsNamedByTypeInTheSpokenSentence`, `testPhonePostureCoachSpeaksAndRecovers`).
The E2E also prints the phone's REAL image-classifier vocabulary (`vision.labels.*`): tune `ObstacleLabelMapper` from it.

**Needs a person with the phone (the part I cannot automate):**
| # | Check | Pass looks like |
|---|---|---|
| A1 | `DEVICE=<id> make selftest-scan`, hold the phone UPRIGHT in portrait facing a wall | console line shows `posture pitch~0 roll~0` |
| A2 | tilt the top of the phone toward the floor, then toward the ceiling | pitch goes negative (down) then positive (up). **If a sign or axis is wrong, tell me: it is one function (`PostureMonitor.reading`)** |
| A3 | lean the top of the phone to your RIGHT, then LEFT | roll goes positive (right) then negative (left); turn it sideways: about +-90 |
| A4 | Navigate a real map; point the phone at the floor for a second | you HEAR the coaching sentence, feel 3 quick taps, the ping stops; fix it: "Phone position is good" and guidance resumes |
| A5 | headphones on, destination to your RIGHT | the ping is in your RIGHT ear. (This is the camera-axis fix: if it is left/right swapped or comes from above/below, the mapping is wrong) |
| A6 | walk slowly toward a plain wall, then toward a trash can / chair | "Careful ..." then "Stop. You are heading toward a wall." / "...about to walk into a trash can." (the first words may be "Stop. Obstacle directly ahead." for a moment until the object is identified) |
| A7 | walk a straight hallway to a turn | briefing at the start, then "In 10 / 5 / 2 meters, turn ...", then "Turn right." |
Record the results in docs/WORKLOG.md (phone, iOS, pass/fail, the console lines).

## End-to-end (E2E) tests: what exists, what proves what — added 2026-10-17

`DEVICE=<id> make selftest-e2e` runs an in-app, headless E2E on the phone (`Waypoint/App/E2ESelfTest.swift`, launch switch `-autoE2E YES`): device capabilities, the real Documents folder and Keychain, a synthetic L-shaped scan
-> `MapBuilder` -> save (+ binary world-map bytes) -> reload with a fresh store (as after a relaunch) -> export bundle -> import into a second store -> validation (incl. a hostile segment id) -> route -> simulated walk through the follower and the planner
-> bundled sample map -> cloud sign-in + list (only if Supabase is configured; SKIP otherwise). One `[e2e] PASS|FAIL|INFO|SKIP` line per check, exit code 0/1. **Run it on every teammate's phone**: the INFO lines are a capability matrix.

| Layer | Command | Proves | Does NOT prove |
|---|---|---|---|
| Unit (macOS, no phone) | `make test` (57) | all pure logic: model, validation, routing, planner rules, box math, cloud client vs a MOCK server | anything on a device |
| Type-check / build | `make typecheck`, `make check` | the app and the UI tests compile against the iOS SDK | runtime behaviour |
| **On-device E2E** | `make selftest-e2e` | the data path and the platform services on a REAL phone (storage, Keychain, audio engine, capabilities) | LiDAR geometry, relocalization, sound/haptic quality |
| Simulated navigation | `make selftest-sim` | the guidance loop speaks the right cues and arrives (on the sample map) | that it sounds right |
| UI tests on the phone | `make uitest` (5) | every main screen renders, the buttons work, HUD/status text, screenshots | motion through space |
| Scan monitor | `make selftest-scan` (needs a person to walk) | live ARKit numbers: tracking, mesh, box, fps | correctness of the mesh |
| **Not yet automated** | - | real Supabase (SQL + RLS + anonymous auth), two-phone Multipeer, real-room relocalization, audio/haptic feel | needs: a Supabase project or local Postgres (see below), a 2nd phone, a person |

Reference run (2026-10-17, iPhone 16 Pro Max, iOS 27.0.1): **17 passed, 0 failed, 1 skipped (cloud)**. Capability INFO: LiDAR mesh true, mesh+classification true, scene depth true, haptics true; Keychain round trip works on a real device; Documents writable.
Bug the E2E found: the walk said "Continue straight." at every waypoint (every 1.5 m on real scans); fixed in `FeedbackPlanner` (announce on change of KIND, hazards once per hazardous target) with 3 new unit tests; after the fix the on-phone walk reads
"Continue straight, Turn right, Continue straight, Turn left, Continue straight, You have arrived at E2E Room 2.". (The follow-up e2e assertion was then corrected to "no phrase twice in a row"; that final re-run was blocked by the phone locking and is pending.)

**Plan for the missing E2E layer, real backend:** the SQL in `supabase/migrations/0001_init.sql` has never been executed. Two ways to test it: (a) U3 creates the Supabase project (SETUP.md section 5) and runs `tools/supabase-tests/` (ROADMAP U3.3) plus `make selftest-e2e`, which then signs in and lists for real;
(b) locally, with Postgres in Docker or Homebrew plus small stand-ins for Supabase's `auth`/`storage` schemas, to exercise the RLS policies with two fake users. (b) needs a download and is not set up yet.

## Measuring scan performance (lag) — added 2026-10-17

The console line from `make selftest-scan` now also prints `fps=` (AR frames per second; the phone camera delivers up to 60), `fitMs=` (time of the last bounding-box fit, which runs off the main thread) and `overlay=` (mesh drawing on/off).
Do an A/B in the SAME room, walking the same path for ~30 s each, and compare `fps` and how it feels:

```bash
DEVICE=<id> CONFIG=Release make run           # 1. install an OPTIMISED build (Debug builds are much slower; judge lag only on Release)
DEVICE=<id> make selftest-scan                 # 2. overlay ON (default): note fps / fitMs
DEVICE=<id> make selftest-scan EXTRA="-scanOverlay NO"            # 3. overlay OFF: if fps jumps, the drawing of the mesh is the cost
DEVICE=<id> make selftest-scan EXTRA="-scanClassification NO"     # 4. cost of surface classification (~~off by default~~ **Update 2026-10-17:** now ON by default, so this run measures what turning it OFF saves)
```
Reading it: fps near 60 (or the camera's cap) = smooth. `fitMs` in the low tens of ms is fine because it is off the main thread. If overlay OFF is smooth but ON is not, keep the overlay switch for demos and use the HUD + box only while walking.
Everything saved (map JSON, ARWorldMap, mesh) is identical in all four runs; only drawing and the unused classification differ.
**Not measured yet** (phone was locked when this was built, and a desk has no mesh): please paste the 4 lines.

## UI tests that tap and take screenshots on the phone — added 2026-10-17

`DEVICE=<id> make uitest` builds the app + a UI-test runner, installs both on the phone, and runs `WaypointUITests/WaypointUITests.swift` (~~5 tests~~ **Update 2026-10-17 (Claude):** 7 tests: home screen, full simulated walk to arrival,
injected obstacle shows STOP and clears, scan screen shows the live HUD, Share-maps sheet shows the Cloud section). Then it exports every screenshot, screen recording and text note to
`~/Library/Caches/Waypoint/uitest-screens/` (`manifest.json` there maps each file to its test and name). `make uitest ONLY=testSimulatedWalkFinishesAndShowsArrival` runs one test;
`make uitest-shots` re-exports the last run. Screenshots live outside the repo on purpose (they can show your room).

Needs: phone plugged in and unlocked (Auto-Lock to Never), and normally Settings > Developer > Enable UI Automation. **Do not use the phone while the tests run** (2026-10-17: opening another app mid-run hid ours and failed one test with "Navigate button missing"; the recording showed the app launching over another app). First run installs a second small app (the test runner) under your free Apple ID.
Reading results from a script or an LLM agent: `xcrun xcresulttool get test-results summary --path ~/Library/Caches/Waypoint/uitest.xcresult` (pass/fail + failure text), plus the exported files.
When a test fails the run also saves the on-screen element tree as a text attachment ("App UI hierarchy"), which shows exactly what the app displayed.

Reference run (2026-10-17, iPhone 16 Pro Max): 5 of 5 passed (about 90 s). The scan test's HUD note read `Tracking OK | Mapping: not available | Nodes: 1 | Mesh: 0 triangles | no box` with the phone lying on a desk.

**What this proves about the live scan view (U1.4, partly):** the camera feed is live and the HUD shows "Tracking OK". That text is set only when OUR code receives AR frames, so the AR view is
NOT stealing the session delegate (the risk listed in the Level 3 table below). Mesh 0 / no box is expected for a phone lying face-up on a desk looking at a blur. It does NOT yet prove the LiDAR mesh and box appear when the phone
looks at a real room: that still needs someone to hold the phone (`make selftest-scan`).

Limits: cannot move the phone, cannot judge audio/haptics/visual quality of the mesh, cannot use the real LiDAR scene. Taps are scripted by accessibility id (`.accessibilityIdentifier` in Waypoint/UI/*): when you add a button worth testing, give it an id.

## Reporting a result

Add to docs/WORKLOG.md: which check number, phone model + iOS version, pass/fail, console excerpt. A check
is only "verified" once someone has done it on a device and written it down.

**Update 2026-10-17 (Claude):** **Docs hook:** `make test-hooks` (or `sh scripts/test-docs-sync.sh`) runs 15 cases of `scripts/docs-sync.sh` in a throwaway git repo (no phone, no Mac needed).

## Level 4 — new interface (added 2026-10-17, U3; docs/UI_PLAN.md §10)

~~Turn it on: Home → gear → Interface **New**.~~ **Update 2026-10-18 (Claude):** the new interface is now the DEFAULT on a fresh install (switch back: Home → gear → Interface **Classic**). Data source default: **Live** on a LiDAR iPhone, **Demo data** on one without. Scripted launches (`-autoSimulate`, `-autoE2E`, `-autoScan`) and `make uitest` always use the classic screens. Data source: Demo data / Simulated walk / Live.

| # | Check | Phone | Expected |
|---|---|---|---|
| 4.0 | `make test` and `make typecheck` on a Mac | – | FlowTests pass (new); ~~the 50 existing tests still pass~~ **Update 2026-10-17:** the whole suite is 167 tests and passes; typecheck OK |
| 4.1 | Interface **Classic** (default): repeat Level 2 checks | any | exactly the same behaviour as before the change |
| 4.2 | New + Demo data: Scanner end to end (New scan → wait ~15 s → tag a labelled Room → Finish → Review → rename → Share → Try it in Navigate) | any | Finish stays disabled with a reason until mapped + a labelled tag; map with "· demo" appears; rename persists after relaunch |
| 4.3 | New + Demo data: Navigator with **VoiceOver on and eyes closed** | any | can pick a place, start, hear every instruction, reach "You have arrived" without looking; back gesture never ends the route; Stop needs confirmation |
| 4.4 | New + Demo data: Navigator with VoiceOver **off** | any | each screen is introduced aloud ("Spoken prompts"); tap anywhere on the guiding screen repeats; Stop needs a 1 s hold |
| 4.5 | New + Simulated walk, headphones | any | real cues from NavigationController; the UI does NOT speak the same instruction a second time |
| 4.6 | New + Live on a Pro iPhone: scan a hallway, review, navigate it | Pro | live mesh + box in the new scan screen; save works; guidance as in Level 3 |
| 4.7 | Regular iPhone (no LiDAR), New + Live | regular | scanner falls back to demo data with a banner; no crash |
| 4.8 | Settings → Larger Text (AX5), Bold Text, Increase Contrast, Reduce Motion | any | no clipped instructions; no pulsing/animation with Reduce Motion |
| 4.9 | Escort panel during a demo walk: inject obstacle, position lost, fail, skip | any | STOP / lost screens take over; closing the panel clears injected states |



## Update 2026-10-18 (Codex) ? preserved U3 integration notes

The following U3 notes are retained for history. Current integration details are in the newest WORKLOG entry; earlier status claims describe their original checkout.

# Testing — what is proven, and the device test plan

## Update 2026-10-17 (Codex) — schema 3 and real mesh payloads

Verified on Windows: 15 Python tests plus fixtures 1/2/3; browser 43/43
logic/geometry and 16/16 interface checks (including 3D orbit, real in-memory OBJ
bundle load, missing mesh failure, checksum rejection). Cloud checks are mocked.
No claim that Python/browser proves native code compiled or AR buffers are valid.

Pending before merge/deployment:

1. Mac: make test, make typecheck, make check. New RichMapSchemaTests and CloudTests
   cover migration, extent preservation, OBJ format/limits, bundle persistence,
   cloud upload ordering, and corrupt downloaded geometry. Main's other work
   (especially route memory) must be retained when integrating this older U3 base.
2. Supabase: apply 0004_rich_map_schema.sql AFTER 0003; run rich_map_schema.sql,
   canonical_maps.sql and extension_connections.sql. Confirm a schema-2 graph
   can gain an extent and immutable mesh manifest, and stale publication retains both.
3. LiDAR phone: scan a real enclosed room with classification on, tag the room,
   save, inspect map.json schemaVersion=3/extent/meshAssets and mesh-UUID.obj.
   Check actual floor/mesh alignment, bounds, checksum, rendering and export time.
   Classification off or open/unmapped rooms must not invent extents; non-LiDAR
   capture remains graph-only. Large scans must fail explicitly at the export cap.
4. Publish, download to another phone, and connect the web library. Confirm every
   contributor's OBJ loads from their own storage folder, aligns with the route,
   and survives extension and stale upload. Reload/roundtrip a legacy map to verify
   IDs/graph preserved and absent geometry stays absent. Also test offline bundles.

All new native/AR capture and cross-phone mesh behavior: UNVERIFIED ON DEVICE.

## Update 2026-10-17 (Codex) — restored web viewer

Run `python -B web/serve.py`, then open http://127.0.0.1:8000/web/tests.html
(33 routing/validation/cloud-mock checks) and `/web/ui-tests.html` (13 actual DOM
checks). Both suites passed in headless Edge after restoring the viewer; the UI
suite includes canvas clicks, file imports, empty/unreachable maps, mock cloud
and a 390px responsive viewport. The 9 Python validator tests also pass.

Optional Node 20+ runner: `node web/test-web.mjs` (not executed here).
New `RouteVectorTests.swift` uses the same `Samples/route-vectors.json` expectations
as JavaScript. Run `make test` on a Mac before claiming native/browser parity.
Live Supabase sign-in/listing still requires the anon public key and a published
building. No real cloud data was read or written during these mocked checks.

## Update 2026-10-17 (Codex) — existing-building extension checks (pending)

First run `make test` and `make typecheck` on a Mac (new MapExtensionTests included).
In Supabase, apply `0003_extension_connections.sql` after 0002, then run both
`supabase/tests/extension_connections.sql` and `supabase/tests/canonical_maps.sql`.
Expected: success, with PASS notices, and no persistent fixture data. These new
checks are NOT yet verified in this Windows session.

On a LiDAR phone, with an escort for navigation checks:

1. Scan and save a new building; note its ID, nodes and segment. Publish it.
2. Select that building under Scan, choose its saved scan area, and start there.
   Before relocalization/explicit attachment, node count must stay unchanged and
   tagging/save must be disabled. Missing world-map bytes must show an error.
3. After normal tracking returns, stand in a known corridor and tap begin extension.
   More than 2 m from an old corridor/junction (or on a different floor) must reject
   attachment without changing the graph. At a known corridor, one new breadcrumb
   connects to the closest corridor/junction; existing rooms/edges remain intact.
4. Walk into new space, tag a room, save. Same building ID/name, new unique segment,
   old scan files unchanged. Save stops recording. Cancel before save must leave
   the stored map unchanged. A tracking interruption must pause tagging/recording.
5. Publish the extension. On a second phone, refresh and download/import: one shared
   building entry, original and new rooms present, scan files from both contributors
   download. Route to the new room must connect through the old corridor. Re-open
   the building and relocalize from each saved scan area.

All AR alignment, tagging, save, audio and cross-phone behavior: UNVERIFIED ON DEVICE.

Three levels. Always run level 1 before handing off; levels 2-3 are for people with a phone.

## Level 1 — automated, no phone (`make test`, `make typecheck`, `make check`)

`make test` runs 45 XCTest cases in `Package/WaypointCore/Tests/` in about a second. They prove:
data model + JSON + merge + validation (hostile maps), routing (A*, stairs), bearings, the feedback rules,
obstacle hysteresis, room-number parsing, the scan bounding box, export budget, the simulated walker
(an END-TO-END walk to Room 204 that must end in "You have arrived"), and the whole Supabase client
(request shapes, sign-in/refresh/401 retry, push order, hostile downloads) against a MOCK server.
`make typecheck` / `make check` prove the iOS app compiles. NONE of this proves AR/audio/haptics/cloud
behave correctly on real hardware or against a real Supabase project.

## Level 2 — on a phone, but no scan needed (any iPhone; headphones for audio)

Run after SETUP.md §3 (`DEVICE=<id> make run`). Owner B/D. Mark each result in docs/WORKLOG.md.

| # | Check | Pass looks like |
|---|---|---|
| 2.1 | App launches; Camera + Local Network prompts appear; Home shows "1 map(s)" (seeded sample) | no crash, prompts answered |
| 2.2 | Navigate -> pick the sample map -> "Simulate walk to Room 204" | status "Simulating walk"; spoken "Navigating to Room 204…", then "Continue straight." |
| 2.3 | Wear headphones; listen during 2.2 | a ping that sits ahead/centre while walking, swings to the RIGHT during the last leg |
| 2.4 | Same run: haptics | right turn into Room 204 = two sharp taps; arrival = rising pattern |
| 2.5 | "Inject obstacle" toggle during a simulation | immediate "Stop. Obstacle ahead." + long buzz; ping goes silent; toggling off resumes |
| 2.6 | "Simulate, starting facing the wrong way" | hears "Turn around." first |
| 2.7 | Share maps with two phones nearby | "Connect to <phone>?" alert on the other phone; Send -> "Import this map?" alert; map appears after Import |
| 2.8 | Share maps -> Export (AirDrop) | share sheet opens with a `.waypointmap` file |
| 2.9 | Cloud (needs Supabase set up, see SETUP.md) | status "Cloud ready"; Upload then Refresh shows the map; a second phone can Download the shared one after an Import tap |

## Level 3 — Pro iPhone with LiDAR in a real hallway (owner A/C)

| # | Check | Pass looks like |
|---|---|---|
| 3.1 | Scan a building -> Start scanning | mesh overlay grows over the camera as you walk; green box appears and tracks the space; HUD shows triangles + box size |
| 3.2 | Box margin +/- | box grows/shrinks immediately |
| 3.3 | Tag Room / Door / Stairs while walking | node count rises; nothing crashes |
| 3.4 | Walk until "Mapping: mapped" -> Save map | "Saved N nodes"; map listed on Home |
| 3.5 | **Relocalization:** kill the app, relaunch, Navigate on the saved map, stand where you started | status reaches "Navigating" within ~30 s, in >= 4 of 5 tries. If not: marker fallback (docs/ROADMAP.md stream 2) |
| 3.6 | Walk the route with headphones | ping direction matches reality; turns announced at the right places |
| 3.7 | Walk toward a wall / a person | caution at ~1.2 m, stop at ~0.6 m (tune thresholds in ObstacleClassifier/Detector) |
| 3.8 | Point the camera at a door sign | (SignReader is not wired into a screen yet) check the console for "confirmed room number" once wired |
| 3.9 | Dress rehearsal | blindfolded teammate + escort reaches the target room |

## Reading logs from the phone

`DEVICE=<id> make launch` streams `os.Logger` output (subsystem ~~`edu.virginia.waypoint`~~ **Update 2026-10-17:** `io.github.sachin-khanal.waypoint`, categories:
app, capture, reloc, nav, guidance, vision, sync). Include relevant lines when reporting a bug.

**Update 2026-10-17 (found by testing on a phone):** ~~`make launch` streams `os.Logger` output~~ was wrong: `devicectl --console` captures only stdout/stderr, not the system log, so nothing appeared. `Log.<area>.info/error` (Waypoint/App/Log.swift) now ALSO writes each line to stderr as `[category] LEVEL message`, which is what `make launch` and the self-tests show. The system log is still written for Console.app.

## Headless tests on the phone (no tapping, no screen needed)  — added 2026-10-17

The phone must be **plugged in and UNLOCKED** (set Auto-Lock to Never while testing), with the volume up: the tests really play audio and speech.

| Command | What it does | Pass looks like |
|---|---|---|
| `DEVICE=<id> make selftest-sim` | launches with `-autoSimulate "*"` (**Update 2026-10-18:** `*` = the first labelled place of the first scanned map; ~~`"Room 204"` on the sample map~~; override: `ROOM="Room 206"`): runs the simulated walk, logs every instruction, spoken cue, haptic and beacon direction | ends with `SELFTEST PASS` and exit code 0. Exit 1 = timeout, exit 2 = no map has that destination, `Locked` error = unlock the phone |
| `DEVICE=<id> make selftest-scan` | launches with `-autoScan YES`: starts scanning immediately and prints `scan: tracking | mapping | nodes | meshAnchors | triangles | box` once per second | walk with the phone; `triangles` and `box` should grow. Ctrl-C to stop. Stuck at `meshAnchors=0` = the AR view is not sharing the session (known risk, U1.4) ~~|~~ **Update 2026-10-17:** that cause is ruled out (see "UI tests" below: frames reach our code). `meshAnchors=0` now means the camera is not looking at textured surfaces (aim at a room, not a desk/ceiling) or the phone has no LiDAR |

What these CANNOT check: how the audio sounds, how the haptics feel, what the mesh looks like. A person must judge those. Reference run (2026-10-17, iPhone 16 Pro Max): turn right at bearing 57 deg fired `haptic: turnRight` + `say: Turn right.`, beacon local x=+1.5 (to the right), arrival spoke and fired `haptic: arrived`, `SELFTEST PASS`.

## Accessibility checks on a real phone — added 2026-10-17
**Update 2026-10-17 (22:15):** the automated half is now VERIFIED on the phone (UI tests 7/7, E2E 20/0/1). Handy for helpers: in Simulate mode the screen has "Pause walker", "Inject obstacle", an obstacle-type menu and a phone-held menu, and shows the sentences just spoken (`nav.recentSpeech`).

Automated on the phone (`make selftest-e2e`, `make uitest`): the posture maths, every sentence (printed as `[e2e] INFO phrase.*`), the simulated walk now includes briefing / countdown / landmark phrases, picking an obstacle type changes the spoken sentence, and tilting the simulated phone makes the coach speak and later say "Phone position is good" (UI tests `testObstacleIsNamedByTypeInTheSpokenSentence`, `testPhonePostureCoachSpeaksAndRecovers`).
The E2E also prints the phone's REAL image-classifier vocabulary (`vision.labels.*`): tune `ObstacleLabelMapper` from it.

**Needs a person with the phone (the part I cannot automate):**
| # | Check | Pass looks like |
|---|---|---|
| A1 | `DEVICE=<id> make selftest-scan`, hold the phone UPRIGHT in portrait facing a wall | console line shows `posture pitch~0 roll~0` |
| A2 | tilt the top of the phone toward the floor, then toward the ceiling | pitch goes negative (down) then positive (up). **If a sign or axis is wrong, tell me: it is one function (`PostureMonitor.reading`)** |
| A3 | lean the top of the phone to your RIGHT, then LEFT | roll goes positive (right) then negative (left); turn it sideways: about +-90 |
| A4 | Navigate a real map; point the phone at the floor for a second | you HEAR the coaching sentence, feel 3 quick taps, the ping stops; fix it: "Phone position is good" and guidance resumes |
| A5 | headphones on, destination to your RIGHT | the ping is in your RIGHT ear. (This is the camera-axis fix: if it is left/right swapped or comes from above/below, the mapping is wrong) |
| A6 | walk slowly toward a plain wall, then toward a trash can / chair | "Careful ..." then "Stop. You are heading toward a wall." / "...about to walk into a trash can." (the first words may be "Stop. Obstacle directly ahead." for a moment until the object is identified) |
| A7 | walk a straight hallway to a turn | briefing at the start, then "In 10 / 5 / 2 meters, turn ...", then "Turn right." |
Record the results in docs/WORKLOG.md (phone, iOS, pass/fail, the console lines).

## End-to-end (E2E) tests: what exists, what proves what — added 2026-10-17

`DEVICE=<id> make selftest-e2e` runs an in-app, headless E2E on the phone (`Waypoint/App/E2ESelfTest.swift`, launch switch `-autoE2E YES`): device capabilities, the real Documents folder and Keychain, a synthetic L-shaped scan
-> `MapBuilder` -> save (+ binary world-map bytes) -> reload with a fresh store (as after a relaunch) -> export bundle -> import into a second store -> validation (incl. a hostile segment id) -> route -> simulated walk through the follower and the planner
-> bundled sample map -> cloud sign-in + list (only if Supabase is configured; SKIP otherwise). One `[e2e] PASS|FAIL|INFO|SKIP` line per check, exit code 0/1. **Run it on every teammate's phone**: the INFO lines are a capability matrix.

| Layer | Command | Proves | Does NOT prove |
|---|---|---|---|
| Unit (macOS, no phone) | `make test` (57) | all pure logic: model, validation, routing, planner rules, box math, cloud client vs a MOCK server | anything on a device |
| Type-check / build | `make typecheck`, `make check` | the app and the UI tests compile against the iOS SDK | runtime behaviour |
| **On-device E2E** | `make selftest-e2e` | the data path and the platform services on a REAL phone (storage, Keychain, audio engine, capabilities) | LiDAR geometry, relocalization, sound/haptic quality |
| Simulated navigation | `make selftest-sim` | the guidance loop speaks the right cues and arrives (on a scanned map; ~~the sample map~~ there is no sample any more) | that it sounds right |
| UI tests on the phone | `make uitest` (5) | every main screen renders, the buttons work, HUD/status text, screenshots | motion through space |
| Scan monitor | `make selftest-scan` (needs a person to walk) | live ARKit numbers: tracking, mesh, box, fps | correctness of the mesh |
| **Not yet automated** | - | real Supabase (SQL + RLS + anonymous auth), two-phone Multipeer, real-room relocalization, audio/haptic feel | needs: a Supabase project or local Postgres (see below), a 2nd phone, a person |

Reference run (2026-10-17, iPhone 16 Pro Max, iOS 27.0.1): **17 passed, 0 failed, 1 skipped (cloud)**. Capability INFO: LiDAR mesh true, mesh+classification true, scene depth true, haptics true; Keychain round trip works on a real device; Documents writable.
Bug the E2E found: the walk said "Continue straight." at every waypoint (every 1.5 m on real scans); fixed in `FeedbackPlanner` (announce on change of KIND, hazards once per hazardous target) with 3 new unit tests; after the fix the on-phone walk reads
"Continue straight, Turn right, Continue straight, Turn left, Continue straight, You have arrived at E2E Room 2.". (The follow-up e2e assertion was then corrected to "no phrase twice in a row"; that final re-run was blocked by the phone locking and is pending.)

**Plan for the missing E2E layer, real backend:** the SQL in `supabase/migrations/0001_init.sql` has never been executed. Two ways to test it: (a) U3 creates the Supabase project (SETUP.md section 5) and runs `tools/supabase-tests/` (ROADMAP U3.3) plus `make selftest-e2e`, which then signs in and lists for real;
(b) locally, with Postgres in Docker or Homebrew plus small stand-ins for Supabase's `auth`/`storage` schemas, to exercise the RLS policies with two fake users. (b) needs a download and is not set up yet.

## Measuring scan performance (lag) — added 2026-10-17

The console line from `make selftest-scan` now also prints `fps=` (AR frames per second; the phone camera delivers up to 60), `fitMs=` (time of the last bounding-box fit, which runs off the main thread) and `overlay=` (mesh drawing on/off).
Do an A/B in the SAME room, walking the same path for ~30 s each, and compare `fps` and how it feels:

```bash
DEVICE=<id> CONFIG=Release make run           # 1. install an OPTIMISED build (Debug builds are much slower; judge lag only on Release)
DEVICE=<id> make selftest-scan                 # 2. overlay ON (default): note fps / fitMs
DEVICE=<id> make selftest-scan EXTRA="-scanOverlay NO"            # 3. overlay OFF: if fps jumps, the drawing of the mesh is the cost
DEVICE=<id> make selftest-scan EXTRA="-scanClassification NO"     # 4. cost of surface classification (~~off by default~~ **Update 2026-10-17:** now ON by default, so this run measures what turning it OFF saves)
```
Reading it: fps near 60 (or the camera's cap) = smooth. `fitMs` in the low tens of ms is fine because it is off the main thread. If overlay OFF is smooth but ON is not, keep the overlay switch for demos and use the HUD + box only while walking.
Everything saved (map JSON, ARWorldMap, mesh) is identical in all four runs; only drawing and the unused classification differ.
**Not measured yet** (phone was locked when this was built, and a desk has no mesh): please paste the 4 lines.

## UI tests that tap and take screenshots on the phone — added 2026-10-17

`DEVICE=<id> make uitest` builds the app + a UI-test runner, installs both on the phone, and runs `WaypointUITests/WaypointUITests.swift` (5 tests: home screen, full simulated walk to arrival,
injected obstacle shows STOP and clears, scan screen shows the live HUD, Share-maps sheet shows the Cloud section). Then it exports every screenshot, screen recording and text note to
`~/Library/Caches/Waypoint/uitest-screens/` (`manifest.json` there maps each file to its test and name). `make uitest ONLY=testSimulatedWalkFinishesAndShowsArrival` runs one test;
`make uitest-shots` re-exports the last run. Screenshots live outside the repo on purpose (they can show your room).

Needs: phone plugged in and unlocked (Auto-Lock to Never), and normally Settings > Developer > Enable UI Automation. **Do not use the phone while the tests run** (2026-10-17: opening another app mid-run hid ours and failed one test with "Navigate button missing"; the recording showed the app launching over another app). First run installs a second small app (the test runner) under your free Apple ID.
Reading results from a script or an LLM agent: `xcrun xcresulttool get test-results summary --path ~/Library/Caches/Waypoint/uitest.xcresult` (pass/fail + failure text), plus the exported files.
When a test fails the run also saves the on-screen element tree as a text attachment ("App UI hierarchy"), which shows exactly what the app displayed.

Reference run (2026-10-17, iPhone 16 Pro Max): 5 of 5 passed (about 90 s). The scan test's HUD note read `Tracking OK | Mapping: not available | Nodes: 1 | Mesh: 0 triangles | no box` with the phone lying on a desk.

**What this proves about the live scan view (U1.4, partly):** the camera feed is live and the HUD shows "Tracking OK". That text is set only when OUR code receives AR frames, so the AR view is
NOT stealing the session delegate (the risk listed in the Level 3 table below). Mesh 0 / no box is expected for a phone lying face-up on a desk looking at a blur. It does NOT yet prove the LiDAR mesh and box appear when the phone
looks at a real room: that still needs someone to hold the phone (`make selftest-scan`).

Limits: cannot move the phone, cannot judge audio/haptics/visual quality of the mesh, cannot use the real LiDAR scene. Taps are scripted by accessibility id (`.accessibilityIdentifier` in Waypoint/UI/*): when you add a button worth testing, give it an id.

## Reporting a result

Add to docs/WORKLOG.md: which check number, phone model + iOS version, pass/fail, console excerpt. A check
is only "verified" once someone has done it on a device and written it down.

**Update 2026-10-17 (Codex, U3):** executed rich_map_schema.sql, canonical_maps.sql and extension_connections.sql successfully on connected Supabase after applying 0005_mesh_read_policy.sql and 0006_geometry_validator_alias.sql. Fixtures roll back. Initial rich-map run exposed ambiguous n in geometry validation; 0006 fixes it. Mesh policy definition now uses objects.name. Actual cross-user mesh HTTP downloads and device capture remain unverified. make test/typecheck could not start on Windows (make missing).

**Update 2026-10-18 (Codex, U3 integration):** integrate-u3 resolves U3/main conflicts while retaining main keyframes, optional manifests, USDZ and local-save policy, and adding OBJ payload storage/cloud. Python 22 + browser 62 checks pass. Native make test/typecheck unavailable on Windows: Mac validation required before main push. First-floor demo excluded. Incoming migrations are 0006/0007/0008; earlier U3 numbering in historical notes is superseded.

**Update 2026-10-18 (Codex):** web viewer adds Walk through/Walk to destination, eye-level perspective and double-click/double-tap travel along stored graph connections. Unlabeled points/background edges hidden by default, recoverable with Show unlabeled points; routing data unchanged. Floor 4 currently has no attached mesh: walkthrough shows mapped positions/routes, not real walls. Real geometry appears only when a verified OBJ is available. Browser checks 49 logic/GPU + 19 UI PASS; Python 22 PASS. Physical device/real scan verification pending.

**Update 2026-10-18 (Codex, architectural preview):** maps without an OBJ now generate an explicitly estimated solid building (floor, corridor walls, room shapes and door frames) from the complete saved graph and named places. This supersedes the route-only display described above. Default room sizes/corridor width/wall heights are assumptions; measured extents take precedence. Real OBJ remains preferred. Raw points/labels are never removed from storage. Floor 4 local snapshot is served only by opt-in --preview-map TEMPFILE and ?floor4=1; private snapshot is not committed. Browser checks 51 logic/GPU + 19 UI PASS, Python 22 PASS; physical accuracy unverified.

**Update 2026-10-18 (Codex, route interaction):** selecting a destination reveals its route; in walk mode it retargets travel immediately. Start route follows the selection and reports arrival. Expand map enlarges the canvas while retaining route controls. Browser checks now 51 logic/GPU + 22 UI PASS, including a complete synthetic trip to arrival; actual building geometry/physical routing remains unverified.

**Update 2026-10-18 (Codex, clarified close-up):** layout retained; walking uses a wider perspective, gentler bounded zoom, and arrival just inside the doorway. Inferred rooms have full 2.8 m walls and ceilings during walking, with cutaway overview. Selected path sits on floor; unrelated graph/leader lines removed and wall-hidden labels suppressed only from the current view. All saved names remain in the complete list. 53 logic/GPU + 22 UI checks PASS. Dimensions remain estimates.

**Update 2026-10-18 (Claude):** the app and the web viewer no longer ship or open any sample/placeholder map (only scanned maps). Consequences for tests: (1) `make uitest` needs a phone that holds at least one real scan with a labelled place; its walk tests pick the scanned map with the most places and walk to its last place (check: `testSimulatedWalk...`). (2) `make selftest-e2e` checks `resource.noSampleMap` (the bundle must not contain `rice-hall-sample.json`). (3) An app that already had the old seeded sample removes it on launch. (4) `Samples/rice-hall-sample.json` and `web/fixtures/rice-hall-sample.json` stay as unit-test / web-test fixtures only.
