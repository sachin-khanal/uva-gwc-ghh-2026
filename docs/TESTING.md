# Testing — what is proven, and the device test plan

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
| `DEVICE=<id> make selftest-sim` | launches with `-autoSimulate "Room 204"` (override: `ROOM="Room 206"`): runs the simulated walk, logs every instruction, spoken cue, haptic and beacon direction | ends with `SELFTEST PASS` and exit code 0. Exit 1 = timeout, exit 2 = no map has that destination, `Locked` error = unlock the phone |
| `DEVICE=<id> make selftest-scan` | launches with `-autoScan YES`: starts scanning immediately and prints `scan: tracking | mapping | nodes | meshAnchors | triangles | box` once per second | walk with the phone; `triangles` and `box` should grow. Ctrl-C to stop. Stuck at `meshAnchors=0` = the AR view is not sharing the session (known risk, U1.4) ~~|~~ **Update 2026-10-17:** that cause is ruled out (see "UI tests" below: frames reach our code). `meshAnchors=0` now means the camera is not looking at textured surfaces (aim at a room, not a desk/ceiling) or the phone has no LiDAR |

What these CANNOT check: how the audio sounds, how the haptics feel, what the mesh looks like. A person must judge those. Reference run (2026-10-17, iPhone 16 Pro Max): turn right at bearing 57 deg fired `haptic: turnRight` + `say: Turn right.`, beacon local x=+1.5 (to the right), arrival spoke and fired `haptic: arrived`, `SELFTEST PASS`.

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
