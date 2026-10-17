# Work log

**Newest entry at the TOP.** Every human and agent adds an entry when they finish a block of work.
This is how four people plus LLM agents stay in sync, so be explicit and complete.

## Entry template (copy this)

```
## YYYY-MM-DD HH:MM — <name or agent> — <one-line summary>   [tags: CONTRACT CHANGE | BUILD | DOCS | BUG]
Area: A | B | C | D | shared
Files created:  <paths>
Files edited:   <paths + what changed>
Files deleted:  <paths>
Commands run:   <notable commands>
Verified:       <what you ran and the result, e.g. `make test` -> 25 passed>
NOT verified:   <anything involving a phone/AR/audio/haptics/Multipeer: "UNVERIFIED ON DEVICE">
Open problems / handoff: <what the next person must know>
```

---

## 2026-10-17 — Claude (agent, for Anmol) — Route simplification + sighted debug overlay   [tags: BUILD]
Area: B (Routing/Navigation) + U3 (UI). Branch `route-simplify-and-debug` off `main` (cdd8331).
Trigger: Rice Hall walk - "weird turns: straight, turn right, turn around, then straight" where the route was
"straight then left"; and "the blind user tryout should show the camera and the pathfinding being calculated".

Diagnosis: A* is correct. The GRAPH is a trail of the volunteer's footsteps, so the optimal path over it still
contains their detours. See D-026.
Files created: `Routing/RouteSimplifier.swift` (detour removal + thinning, with a protected-node rule),
`Waypoint/UI/Navigator/NavDebugView.swift` (camera + plan + raw status).
Files edited: `Routing/Router.swift` (`simplify:` parameter, default true; passes hazard-edge endpoints as protected),
`Waypoint/Navigation/NavigationController.swift` (+debug telemetry: activeMap, routeNodeIds, mapPosition,
headingRadians), `Waypoint/UI/DesignSystem/PlanView.swift` (user position/heading arrow; route drawn as its own
polyline - highlighting edges no longer works once straight runs are collapsed), `Waypoint/Services/GuidanceService.swift`
(+`debugController`, nil by default), `LiveGuidanceService.swift` (exposes its controller), `ServiceMode.swift`
(+`ui.debugOverlay`), `SettingsView.swift` (toggle), `GuidingView.swift` (shows the overlay),
`NavigatorModel.swift` (passes the controller through).
Tests added: `RouteSimplifierTests` (8) - there-and-back removed, straight run collapses to its endpoints, a real
corner survives, the simplified path stays within tolerance of every walked point, tagged/protected nodes are never
removed, a detour PAST something tagged is not collapsed, short routes untouched, and segment-vs-infinite-line distance.
A test caught a real safety bug I introduced: the first version of thinning removed a stairs node and its hazard
warning disappeared. Fixed with the protected-node rule, then covered directly.
Three existing tests were updated because the behaviour deliberately changed: `testRouteToRoom204` now pins RAW A*
(`simplify: false`) and a new test pins the simplified walk; the FlowTests route summary expects the collapsed node
list; my own start-gate test asserts the starting node rather than a node count.
Verified: `make test` -> **145 tests, 0 failures** (was 136); `make typecheck` OK (60 app files, 1 UI test file);
`make check` -> BUILD SUCCEEDED.
NOT verified: **UNVERIFIED ON DEVICE.** Nobody has seen the overlay or walked a simplified route. 1.2 m shortcut
radius and 0.6 m tolerance are guesses.
Open / handoff:
1. NOT addressed: the mesh is one blob rather than separated walls/objects, so there is still no notion of being
   "inside a room" - the app drives you to the exact tagged point. This needs room geometry derived from the
   classified mesh and is a bigger change; see the reply to the user, nothing was built for it.
2. Loop closure (D-025) still only applies to maps scanned after that change - old maps remain chains.
3. Still open: off-route re-routing (U2.5).

---

## 2026-10-17 — Claude (agent, for Anmol) — Natural path following, loop closure, doors as doors, turn angles   [tags: BUILD]
Area: B (Navigation/Feedback) + A (MapBuilder). Branch `guidance-path-and-graph` off `main` (73b189c).
Trigger: six findings from walking Rice Hall. Full reasoning in D-025.

Files created (WaypointCore): `Routing/HeadingCue.swift` (turn classification with hysteresis + debounce; also holds
`ArrivalRadius`).
Files edited (WaypointCore):
- `Model/MapBuilder.swift` - LOOP CLOSURE: a new breadcrumb also links to an older node the volunteer walked back to
  (revisitRadius 1.0 m, minChainSeparation 4). This is the fix for "it made me walk around the whole room": the graph
  was a chain, so A* had no short way across a central core.
- `Routing/RouteFollower.swift` - steers at a point 3 m further along the route (`steeringPoint`) instead of the next
  breadcrumb; cue classification delegated to `HeadingCue`; arrival radius now depends on the destination's kind; the
  beacon is placed at the steering point. The two old threshold constants are kept but deprecated.
- `Vision/ObstacleKind.swift` - `RouteFeature.isWayThrough`.
- `Guidance/SpokenPhrases.swift` - `ObstacleSpeech.wayThrough` (says to OPEN the door), `TurnSpeech` (angles rounded to 5 degrees).
- `Guidance/FeedbackPlanner.swift` - way-through handling (caution + keep guiding, instead of stop + silence);
  turn cues use TurnSpeech; `directionCooldownSeconds` = 1.5 s with the held cue re-tried rather than dropped.
Tests added: `NaturalGuidanceTests` (16) - wobble never produces a turn, a real turn must persist, hysteresis, first cue
immediate, steering aims past the next breadcrumb, room vs door arrival distance, a walked loop is closed, parallel
corridors are NOT joined through the wall, doors say "open it" while guidance continues, a person still stops you,
angle rounding, and that directions are spaced out but not lost.
Two tests I wrote FAILED first and found real problems: (1) the follower only evaluates arrival once it has stepped
through to the last node, so the test had to walk the route rather than teleport; (2) my first "parallel corridors"
assertion was wrong - the edge joining the end of one corridor to the start of the next is a legitimate CHAIN edge the
volunteer walked. Rewritten to assert the graph stays a pure chain. Also tightened revisitRadius 1.2 -> 1.0 m.
Three existing tests asserted the old wording ("Turn left.") and now match a prefix, since the angle is TurnSpeech's job.
Verified: `make test` -> **136 tests, 0 failures** (was 120); `make typecheck` OK (59 app files, 1 UI test file);
`make check` -> BUILD SUCCEEDED.
NOT verified: **UNVERIFIED ON DEVICE.** Every threshold is a guess: 3 m lookahead, 45/22 degree deadband, 3-tick
debounce, 1.0 m revisit radius, 1.5 s direction cooldown, arrival radii 2.5/1.2/1.5/1.0 m. They want one real walk.
Open / handoff:
1. Loop closure only helps maps scanned AFTER this change - existing saved maps are still chains. Rescan Rice Hall.
2. A room has no extent in the model (a MapNode is a point), so "inside the room" is approximated by a 2.5 m radius.
   Real room bounding boxes would be a shared-model change.
3. Still open: the mesh-detail question, and off-route re-routing (U2.5).

---

## 2026-10-17 — Claude (agent, for Anmol) — One voice: single synthesizer; merged main into the UI branch   [tags: BUILD]
Area: B (Guidance) + U3 (UI services). Branch `app-ui-workflows`.
Trigger: "sometimes multiple voice lines speak at the same time, especially when reaching the destination", heard while
testing the new UI.

Merge first: `git merge main` into `app-ui-workflows`, bringing 4e90396 (E2E framework), 7fbcb76 (obstacle
identification + speech guidance) and 2d7aca7 (arrival / start-gate fixes). ONE conflicted file, `Waypoint/UI/RootView.swift`,
two hunks, both resolved by keeping BOTH sides (the UI branch's Settings gear and new-interface auto-open, plus main's
accessibility identifiers and the `-autoE2E` self-test task). Nothing was dropped. -> `make test` 112 passed.

Cause of the overlap: `SpeechGuide` and `Announcer` each owned an `AVSpeechSynthesizer`. Each one's anti-overlap logic
only applied to its own instance, so they could never prevent each other; at arrival both spoke. With VoiceOver on it was
worse - Announcer posted a VoiceOver announcement while SpeechGuide spoke aloud.
Files created: `Waypoint/Guidance/Speaker.swift` (the app's only synthesizer), `Package/WaypointCore/Sources/WaypointCore/Guidance/SpeechGate.swift`
(the rules: interrupt on `.high`, drop `.normal` while busy, drop identical text inside 3 s - pure logic so it is testable).
Files edited: `Waypoint/Guidance/SpeechGuide.swift` (now a thin forwarder; same API, so `NavigationController` is untouched),
`Waypoint/Services/Announcer.swift` (forwards to Speaker; no longer posts a VoiceOver announcement for `say` - see the
trade-off in D-024), `docs/DECISIONS.md` (+D-024).
Tests added: `SpeechGateTests` (8) - interrupt vs drop, repeat window, different text never suppressed, empty text,
reset, and that a DROPPED line does not reserve the repeat window.
Verified: `make test` -> **120 tests, 0 failures**; `make typecheck` OK (59 app files, 1 UI test file); `make check` ->
BUILD SUCCEEDED. `grep "AVSpeechSynthesizer()"` now matches exactly ONE line in the whole repo (Speaker.swift).
NOT verified: **UNVERIFIED ON DEVICE.** Nobody has heard it. The thing to listen for is arrival with the new UI in
Live mode: one voice, one arrival sentence, no second line on top.
Open / handoff:
1. Test on a phone, with and without VoiceOver.
2. Still open: mesh detail question (see the previous entry); off-route re-routing (U2.5).
3. My account-auth work is still in `stash@{0}`; its ADR claims D-019 and needs renumbering to the next free id.

---

## 2026-10-17 — Claude (agent, for Anmol) — Arrival vs obstacle, route start race, speech clipping   [tags: BUILD, CONTRACT CHANGE]
Area: B (Navigation/Feedback) + shared core. Branch `guidance-arrival-and-start` off `main` (7fbcb76).
Trigger: three issues found testing on the iPhone 15 Pro.

CONTRACT CHANGE: `GuidanceInstruction` gains `targetKind: NodeKind?` (optional, defaulted last in the initializer, so
every existing call site and the on-disk map JSON are unaffected; `BuildingMap.schemaVersion` NOT bumped - no JSON change).
`RouteFollower` fills it from the target node.

Files created (WaypointCore): `Routing/StartGate.swift` (pure logic: N consecutive ticks within maxJump before the
first route may be computed).
Files edited (WaypointCore): `Routing/GuidanceInstruction.swift` (+targetKind), `Routing/RouteFollower.swift` (sets it on
both the arrival and the normal instruction), `Guidance/SpokenPhrases.swift` (+`ArrivalSpeech`, phrasing driven by
NodeKind, plural agreement for stairs), `Guidance/FeedbackPlanner.swift` (new step 1b: arrival is handled before
obstacles and returns; the old `.arrived` case in step 4b is now unreachable and says so).
Files edited (app): `Waypoint/Navigation/NavigationController.swift` (StartGate gates follower creation + reset in
`begin`; `perform` coalesces a tick's `.speak` actions into one utterance at the highest priority).
Tests added: `ArrivalAndStartGateTests` in RoutingTests - arrival wording per NodeKind, arrival announced at STOP range,
said once not per tick, obstacle warnings unchanged while walking, gate waits out a jumping pose, lost tracking restarts
the count, non-finite rejected, and a routing test showing the converging pose picks the scan-origin node (4-node route)
while the settled pose picks the right one (2-node route).
Verified: `make test` -> **91 tests, 0 failures** (was 81); `make typecheck` OK (22 app files, 1 UI test file);
`make check` -> BUILD SUCCEEDED.
NOT verified: **UNVERIFIED ON DEVICE.** Nobody has heard the new arrival wording or confirmed the gate fixes the
walk-back-to-the-scan-origin behaviour on a phone. `StartGate` defaults (10 ticks, 0.35 m) are a guess and want tuning
in a real corridor - at ARKit's ~60 Hz that is ~0.17 s, at the simulator's 10 Hz it is 1 s.
Open / handoff:
1. Re-test the original two reports on a phone: arrive at a labelled door, and start navigation from a spot far from
   where the scan began.
2. Still open, NOT in this branch: the third report (mesh detail / "polygon calcs") - no mesh is stored anywhere and
   ARKit's reconstruction resolution is not tunable, so the question back to the team is which symptom was actually
   seen (overlay density, frame rate/heat, or a reported size).
3. Still open: the dual-synthesizer overlap on `app-ui-workflows` (Announcer + SpeechGuide), and off-route re-routing
   (U2.5), which would also recover from a bad start node rather than only preventing one.
4. My earlier account-auth work is still in `stash@{0}` and its ADR must be renumbered (it claims D-019, which is taken; the next free id after this entry is D-024).

---

## 2026-10-17 22:45 — Claude (agent, for Sachin) — Branch review before commit: app-ui-workflows is merge-safe with one fix   [tags: BUILD]
Area: shared (integration check requested by U1 before committing)
Branches: `origin/U3` = no own commits (old pointer, 3 behind main). `origin/app-ui-workflows` (neehamikki, ca2ece5) = 1 commit, 49 files / ~5,100 lines: new Scanner + Navigator interface behind a default-OFF "Interface" setting,
  WaypointCore `Flows/*` + 21 `FlowTests`, `Waypoint/Services/*` (mock + live adapters around CaptureController/NavigationController), design system. Based on 27365ec (older than main), written on Windows, never compiled before this check.
Method: throwaway git worktree outside the repo = main + ALL of Sachin's uncommitted work, then `git merge origin/app-ui-workflows`; nothing in the real working tree was touched except the fix below; worktree and its build folders deleted afterwards.
Findings: (1) no duplicate type names in WaypointCore or the app; (2) their logging, CaptureController and NavigationController calls are all still valid (APIs only gained defaulted params);
  (3) ONE compile break: their `LiveScanScreen.swift:68` calls `LiveScanView(session:box:)`, but today's lossless pass added a required `showMesh:` -> fixed on OUR side with a default (`var showMesh: Bool = true`), applied to the working tree;
  (4) ONE textual conflict, `Waypoint/UI/RootView.swift` (both edited the toolbar + modifier chain): resolution = keep both (our `toolbar.home` id + `-autoE2E` task, their gear/Settings sheet/auto-open; gear gets id `toolbar.settings`); docs auto-merged cleanly.
Verified on the MERGED code: unit tests 102/102 (81 ours + 21 theirs); type-check 58 app files, 0 errors, 0 warnings; signed `build-for-testing` for the iPhone 16 Pro Max succeeded; ON DEVICE `make uitest`-equivalent 7/7 and the in-app E2E 20/0/1 (Classic interface unchanged). Sachin's own build was reinstalled afterwards.
NOT verified: their NEW interface (Interface = New) at runtime - no UI tests cover it yet; their Live adapters with a real scan/route.
Note: the commit labels its work "U3 (UI flows)"; per ROADMAP Revision 3 the author's lane (Windows + non-Pro iPhone 17) is U4. Worth agreeing who owns `Waypoint/UI/{Scanner,Navigator}` + `Waypoint/Services` going forward.

---

## 2026-10-17 22:15 — Claude (agent, for Sachin) — Accessibility features verified on the phone; UI churn fixed; config-tracking question answered   [tags: BUILD, BUG]
Area: B/D; U1 said the phone's VPN profile prevents auto-lock, so tests were run directly.
Verified ON DEVICE (iPhone 16 Pro Max): `make uitest` 7/7 (was 5; +`testObstacleIsNamedByTypeInTheSpokenSentence`, +`testPhonePostureCoachSpeaksAndRecovers`); `make selftest-e2e` 20 passed / 0 failed / 1 skipped (cloud); unit tests 81/81; `make typecheck` OK.
Phone's REAL Vision vocabulary (1,303 labels) for tuning `ObstacleLabelMapper`: trash -> `trash_can` (only one); people -> adult, baby, child, crowd, people (no plain "person"); seating -> armchair, bench, chair, chair_other, folding_chair, high_chair, seat, sofa, stool, swivel_chair, wheelchair (+car_seat, toilet_seat);
  furniture -> bed, cabinet, cart, desk, refrigerator, shopping_cart, table; structure -> door, elevator, escalator, stairs, window (+glass types); objects -> backpack, bicycle, cardboard_box, decorative_plant, extinguisher, flower, luggage, machine, plant, pole, sign, stroller, suitcase. No "wall" label: walls rely on the ARKit mesh class.
Bugs found by the on-device UI tests and fixed:
 1. The navigation screen was re-rendered 10x per second even when nothing changed (assigning equal values to @Published properties). It kept the app from ever going idle, so UI tests waited minutes (145 s -> 26 s for the same test after the fix). Now `setIfChanged` (also saves battery on a real walk). Same class of bug as the scan HUD fix.
 2. Posture recovery said "Phone position is good." and, in the same tick, "Continue straight.", so the confirmation was instantly replaced. The planner now says only the confirmation on that tick and resumes guidance on the next (unit test updated).
 3. UI tests raced the 15-second simulated walk; added a "Pause walker" control (`nav.pauseWalk`, useful for a sighted helper too) and a short speech history on screen (`nav.recentSpeech`).
Files edited: `Waypoint/Navigation/NavigationController.swift` (setIfChanged, `simulationPaused`, `recentSpeech`), `Waypoint/UI/NavigatorView.swift`, `Waypoint/Guidance/FeedbackPlanner.swift`... (path: Package/.../Guidance/FeedbackPlanner.swift), `Tests/.../AccessibilityGuidanceTests.swift`, `WaypointUITests/WaypointUITests.swift`, `Package/.../Vision/ObstacleKind.swift` (+`.furniture`; chair += wheelchair), `Waypoint/Capture/CaptureController.swift` (posture in the scan line).
STILL NOT verified (needs a person holding the phone): the real-phone posture axes/signs (TESTING.md A1-A3), the beacon being in the correct ear (A5), real depth hits and naming of real objects (A6), hallway countdown timing (A7), haptic feel, calibration, and blind-user review of the wording.
Config question answered: tracked = `Config/Base.xcconfig` (shared defaults, bundle prefix, empty Supabase placeholders) and `Config/Local.xcconfig.example` (template), `project.yml`; NOT tracked = `Config/Local.xcconfig` (your team id, dev suffix, and later the Supabase URL + anon key) - git-ignored and never committed (checked all history).

---

## 2026-10-17 21:30 — Claude (agent, for Sachin) — Accessibility: phone-posture coach, named obstacles, distance-aware instructions   [tags: BUILD, BUG, CONTRACT CHANGE]
Area: B (guidance), C (vision), shared geometry; requested by U1 ("remember this is for visually impaired": posture stabilization + explicit/granular instructions + object-type classification)
Files created (core, tested): `Guidance/PhonePosture.swift`, `Guidance/SpokenPhrases.swift`, `Vision/ObstacleKind.swift`, `Tests/.../AccessibilityGuidanceTests.swift` (24 tests).
Files created (app): `Waypoint/Vision/ObstacleIdentifier.swift` (mesh class lookup + Vision `VNClassifyImageRequest` on a crop).
Files edited (code): `Guidance/FeedbackPlanner.swift` (REWRITTEN: posture, obstacle kinds + repeat, briefing, 10/5/2 m countdown, landmarks; new haptic cue `.holdPhoneUpright`), `Routing/GuidanceInstruction.swift` (+`Maneuver`, `Landmark`, optional fields), `Routing/RouteFollower.swift` (look-ahead along the route, landmarks),
  `Geometry/Geometry.swift` (`cameraTransform` now ARKit's real portrait convention + pitch/roll; `cameraLocalToUser`), `Tests/.../ScanAndSimulationTests.swift` (camera test updated), `Waypoint/Vision/ObstacleDetector.swift` (REWRITTEN), `Waypoint/Navigation/NavigationController.swift`, `Waypoint/Relocalization/Relocalizer.swift` (labelled mesh during navigation),
  `Waypoint/Guidance/HapticsGuide.swift`, `Waypoint/UI/NavigatorView.swift` (obstacle-type and phone-held pickers, on-screen "what was just said"), `Waypoint/Capture/CaptureController.swift` (posture reading in the scan monitor), `Waypoint/App/E2ESelfTest.swift` (+posture, phrases, Vision vocabulary), `WaypointUITests/WaypointUITests.swift` (+2 tests).
Docs (strike/update): `docs/DECISIONS.md` (D-022), `docs/TESTING.md` (accessibility checks A1-A7), `docs/ROADMAP.md` (A11Y-1..6), `docs/MODULES.md`.
REAL BUG FOUND while designing posture: ARKit's camera frame is fixed to the sensor (portrait: +x toward the BOTTOM of the phone, +y toward the user's right). The real-device audio beacon treated camera-local x as "right"; the simulation's fake camera hid it. Fixed centrally (`Geometry.cameraLocalToUser`); the old depth region was also the wrong shape for portrait and the floor could look like an obstacle (now world-space + `ObstacleBand`).
  These fixes are derived from Apple's documented axes and proven only with synthetic poses -> MUST be confirmed on a real phone (TESTING.md A1-A5).
Verified: `make test` 81/81 (24 new: posture round trip at any heading, dwell/hysteresis/repeat/recovery, label mapping with whole-word matching, every spoken sentence verbatim, look-ahead turn/stairs/arrival distances along the route, landmarks, planner countdown with no bursts, posture mutes guidance but not obstacle warnings);
  `make typecheck` OK (22 app files + UI tests). ON DEVICE (iPhone 16 Pro Max): `make selftest-e2e` -> 20 passed, 0 failed, 1 skipped (cloud): posture math ok (upright 0/0, down -49, lean +39), the simulated L-shaped walk now says "Walk straight about 12 meters, then turn right. / In 10 meters... / E2E Room 1 on your right. / In 5 ... In 2 meters, turn right. / Turn right. ...  In 2 meters, you will arrive at E2E Room 2." and ends with arrival;
  Vision on this phone: 1,303 labels incl. trash_can, chair/folding_chair/swivel_chair/armchair/wheelchair, door, stairs, table, window, plant/decorative_plant, cabinet; no label for "wall" or "person" was in the first list (so walls rely on the ARKit mesh class); the classifier runs without error.
NOT verified: ~~(1) the two new UI tests and the rest of `make uitest` after these changes (phone locked); (2) the wider `vision.labels.*` printout (phone locked on the rerun; mapper extended with cabinet/wheelchair from the first list);~~ **Update 2026-10-17 (22:15): (1) and (2) are DONE, see the next entry.** (3) everything that needs a person holding the phone: real posture axes, ear/direction of the beacon, real depth hits, mesh-class and Vision naming of real objects, thresholds, haptic feel, and any blind-user review of the wording.
Open: U1/U2 do TESTING.md A1-A7; U4 reviews wording; unlock the phone and run `make uitest` + `make selftest-e2e`.

---

## 2026-10-17 20:05 — Claude (agent, for Sachin) — End-to-end testing on the phone; found + fixed repeated "Continue straight."   [tags: BUILD, BUG]
Area: D (E2E harness), B (planner fix); requested by U1 ("continue testing, how about e2e")
Files created: `Waypoint/App/E2ESelfTest.swift` (A device capabilities, B storage + Keychain, C synthetic scan -> save -> reload -> share -> validate -> route -> simulated walk, D bundled resource, E optional cloud read).
Files edited (code): `Waypoint/App/LaunchCommand.swift` (+`.e2e`, `-autoE2E YES`), `Waypoint/App/AppState.swift`, `Waypoint/UI/RootView.swift` (runs the E2E once then `exit(0/1)`), `Makefile` (+`selftest-e2e`),
  `Package/.../Guidance/FeedbackPlanner.swift` (announce on change of instruction KIND, not on every new target; hazard announced once per hazardous target; reset clears it), `Tests/.../FeedbackAndVisionTests.swift` (+3 tests).
Docs (strike/update where needed): `docs/TESTING.md` (new E2E section + layer table + plan for the real-backend layer), `AGENTS.md` (+`selftest-e2e` row).
Bug found by the on-device E2E: with real-scan spacing (a node every 1.5 m) the planner spoke "Continue straight." at every waypoint (the sample map's 3 m spacing hid it). Fixed; unit tests 57/57.
Verified ON DEVICE (iPhone 16 Pro Max, iOS 27.0.1): E2E run 1 -> 17 passed, 0 failed, 1 skipped (cloud not configured). Capability matrix: LiDAR mesh yes, mesh+classification yes, scene depth yes, haptics yes, en-US voice yes, text recognition yes, audio engine starts, Documents writable, Keychain round trip works.
  Run 2 (after the planner fix): the walk spoke "Continue straight / Turn right / Continue straight / Turn left / Continue straight / arrived" (correct for an L-shaped hallway); my own assertion (<= 2 straights) was wrong -> 16 passed 1 failed; assertion corrected to "no phrase twice in a row".
  `make selftest-sim` after the fix: Turn right, Continue straight, You have arrived at Room 204, PASS.
NOT verified: the corrected E2E assertion on the phone (phone locked at the final rerun); real Supabase (SQL never executed anywhere; Docker daemon is not running here, no Supabase CLI); two-phone Multipeer; LiDAR geometry; relocalization; audio/haptic feel.
Open: (1) U1 unlock the phone and rerun `make selftest-e2e` (expect 17/0/1). (2) Run it on other teammates' phones (esp. the non-LiDAR ones: expect `lidar.mesh false`). (3) Decide how to E2E-test the SQL: Supabase project (U3) or local Postgres via Docker/Homebrew (needs a download; not done without approval).

---

## 2026-10-17 19:20 — Claude (agent, for Sachin) — "Keep lossless": classification default ON + start-screen switch; test status check   [tags: BUILD, DOCS]
Area: A (scan); requested by U1 ("keep lossless, implement the changes; what's happening with the current tests?")
Files edited (code): `Waypoint/Capture/CaptureController.swift` (`start(mapName:recordSurfaceLabels:)`; classification ON by default, `-scanClassification NO` to disable; logs `surfaceLabels=`), `Waypoint/UI/VolunteerView.swift` (start form toggle "Record surface labels", id `scan.labels`),
  `WaypointUITests/WaypointUITests.swift` (re-activate the app if it is not in the foreground; header warns not to use the phone during a run).
Docs (strike/update): `docs/DECISIONS.md` (D-020 item 4 struck + updated; new D-021 lossless-first policy, vector layer parked, capture-vs-display reversibility rule), `docs/TESTING.md` (A/B step 4 wording; "do not touch the phone" note).
Test status right now: unit tests 54/54 pass (`make test`); `make typecheck` OK (20 app files + 1 UI test file); `make check`/test-bundle build OK; ON THE PHONE `make uitest` 5/5 pass after the change (earlier today 5/5 too).
Failures seen and explained: (1) toggle tapped in its middle (test bug, fixed); (2) one-off "Home screen missing" and (3) one-off "Navigate button missing": both runs started with the app NOT usable in the foreground; the recording for (3) shows the app launching over another app ("<| Instagram" in the status bar), i.e. the phone was being used mid-run. Not app bugs; mitigated with re-activation + the do-not-touch note.
Not run / not verified: the lag A/B numbers (needs a real room + someone holding the phone), `make selftest-sim` after the latest change (UI test covers the same screen text), anything on LiDAR mesh content, relocalization, cloud.
Open: U1 still owes TESTING 3.1-3.6 in a real room. Classification is now on, so expect slightly more compute while scanning; use the A/B recipe to see what it costs.

---

## 2026-10-17 18:40 — Claude (agent, for Sachin) — Scan lag: lossless performance pass   [tags: BUILD]
Area: A (scan) ; requested by U1: "make this lag a lot less ... only if it's lossless"
Diagnosis (from code, NOT yet measured on a phone - nobody had a real mesh running while I could observe): (1) RealityKit `.showSceneUnderstanding` redraws the whole mesh every frame; (2) box fit on the main thread, brute force, every 6th vertex only;
(3) ~60 unnecessary SwiftUI re-renders/s from @Published writes of unchanged values; (4) plane detection on but unused; (5) per-face classification on but unused; (6) Debug (unoptimised) builds.
Files created: `Package/.../Scan/ConvexHull2D.swift`. Files edited (code): `Scan/OrientedBox.swift` (`fitBest` now hull-based and EXACT; `fitBest(hull:minY:maxY:)`; brute force kept as `fitBestBruteForce` for tests), `Tests/.../ScanAndSimulationTests.swift` (+4 tests in `FastBoxFitTests`),
  `Waypoint/Scan/MeshSampler.swift` (REWRITTEN: `measure` reads ALL vertices, per-anchor hulls), `Waypoint/Capture/CaptureController.swift` (background fit with no overlap, publish-only-on-change, classification/plane detection off by default, fps/fitMs/overlay telemetry, `showMeshOverlay`),
  `Waypoint/Scan/LiveScanView.swift` (overlay switch, unused render effects off), `Waypoint/UI/VolunteerView.swift` (overlay toggle, id `scan.overlay`), `Makefile` (`EXTRA=` passes launch args to `selftest-scan`).
Docs (strike/update): `Architecture.md` (risk row), `docs/DECISIONS.md` (D-020 rules + what was deliberately NOT done), `docs/TESTING.md` (new "Measuring scan performance" A/B recipe).
Verified: `make test` -> 54 tests, 0 failures. The new equivalence test proves the fast box equals the brute-force box on 60 random clouds (that is what "lossless" means for the box); 300k-point fit in a DEBUG test build: brute force 484 ms vs hull 254 ms (sorting dominates there; in the app each anchor is hulled separately and off the main thread).
  `make typecheck` OK; `make build` and `CONFIG=Release make build` -> BUILD SUCCEEDED (Debug installed on the phone).
NOT verified: any improvement on a real phone (no before/after numbers yet); the app launch after this change (phone was LOCKED, so the regression run of `make selftest-sim` could not start); LiDAR mesh in a real room.
Honest limits: if the dominant cost is ARKit's own mesh reconstruction + camera pipeline (system code), none of this can remove it; the remaining lossless lever is the overlay switch. Things that would help but are NOT lossless and were not done: lower video resolution/fps, decimating meshes, slower mesh updates.
Next for U1: unlock the phone, run the 4-step A/B in docs/TESTING.md, paste the `scan:` lines. U2/U3 can reuse `EXTRA=` for other launch flags.

---

## 2026-10-17 18:00 — Claude (agent, for Sachin) — UI tests on the phone from the CLI (taps + screenshots); first scan-screen evidence   [tags: BUILD]
Area: D (tests) with A/B findings; requested by U1 ("yes do 1 and 2")
Tools check: I have NO desktop computer-use tool (twice searched; only browser/Figma-scoped ones surfaced), so no mirroring. Substitute built: scripted UI tests on the device itself.
Files created: `WaypointUITests/WaypointUITests.swift` (5 tests; attaches screenshots + HUD values; interruption monitor accepts permission prompts; returns to Home at start).
Files edited (code/config): `project.yml` (+`WaypointUITests` target `bundle.ui-testing`, explicit `Waypoint` scheme that runs it), `Makefile` (+`uitest`, `uitest-shots`, `ONLY=`), `scripts/typecheck.sh` (also type-checks the UI tests; needs `-F <platform>/Developer/Library/Frameworks -I <platform>/Developer/usr/lib`),
  `Waypoint/UI/RootView.swift`, `VolunteerView.swift`, `NavigatorView.swift` (stable `.accessibilityIdentifier`s: mode.navigate, mode.scan, toolbar.home/share, scan.start/save/tag.*, hud.tracking/mapping/mesh/box, nav.simulate.*, nav.status/instruction/obstacle/injectObstacle/stop).
Docs (strike/update where old text changed): `docs/TESTING.md` (new UI-test section; Level-3 "meshAnchors=0" explanation struck + updated), `AGENTS.md` (+`make uitest` row), `docs/SETUP.md` (+headless testing note).
Verified ON DEVICE (iPhone 16 Pro Max): `make uitest` -> 5 of 5 passed. Along the way: (a) a UI-test compile error caught by `make typecheck` (helper named `wait(for:)` clashed with XCTest) -> fixed; (b) obstacle test first failed because tapping a Toggle row in its middle does not flip it (tap the switch at the right edge) -> fixed;
  (c) one run failed with "Home screen missing": the app was on the Navigator picker at launch (cause not found; a normal launch is clean) -> made `setUp` return to Home; 5/5 afterwards. If it recurs, check `app launch command` lines in the console.
Scan-screen evidence (phone lying on a desk): Tracking OK, Mapping not available, Nodes 1, Mesh 0 triangles, no box; screenshot shows live (blurry) camera + HUD + controls rendered. Conclusion: our AR delegate receives frames, so the "AR view steals the session" risk is ruled out; mesh/box on a real scene is STILL UNVERIFIED (needs the phone held up in a room).
Observed: `devicectl list devices` also lists "Neeha's iPhone" (iPhone 17, unavailable) - a teammate's phone was connected to this Mac before; a non-LiDAR iPhone 17 can be used for the no-LiDAR QA (U4 tasks) once connected.
NOT verified: LiDAR mesh/box in a real room; audio quality; haptic feel; cloud (not configured); relocalization.
Open for U1: hold the phone in a room and run `DEVICE=00008140-000914590E01801C make selftest-scan` (or the Scan screen by hand) -> U1.4, then U1.5/U1.6.

---

## 2026-10-17 17:10 — Claude (agent, for Sachin) — Headless on-phone testing + first real device run; arrival-speech bug found and fixed   [tags: BUILD, BUG]
Area: B (guidance) + D (harness); requested by U1 ("can you test this headless / CLI?")
Findings before building anything:
- I have NO tool that can see/click the Mac screen (only browser/Figma tools), so iPhone Mirroring cannot be driven by me. It is also unsuited to AR (phone must be locked while mirrored; camera/AR likely unavailable - not verified).
- `devicectl --console` showed NOTHING from the app: it captures stdout/stderr only, and we logged with os.Logger. The earlier docs claim "make launch streams logs" was wrong (struck through in docs/TESTING.md).
Files created: `Waypoint/App/LaunchCommand.swift` (launch-argument switches `-autoSimulate "<label>"`, `-autoFacingAway YES`, `-autoScan YES`).
Files edited (code): `Waypoint/App/Log.swift` (REWRITTEN: `AppLog` writes to os.Logger AND stderr), `Waypoint/App/AppState.swift` (reads the launch command, picks the mode), `Waypoint/UI/NavigatorView.swift`
  (auto-runs the simulated walk, exits 0/1/2), `Waypoint/UI/VolunteerView.swift` (auto-starts scanning), `Waypoint/Capture/CaptureController.swift` (1 Hz `scan:` status line),
  `Waypoint/Navigation/NavigationController.swift` (logs instruction changes, haptics, beacon direction ~1/s), `Makefile` (`selftest-sim`, `selftest-scan`, `ROOM=`; app args need a `--` after the bundle id),
  `Package/.../Guidance/FeedbackPlanner.swift` (arrival, turns, hazards now `.high` speech priority) and `Tests/.../FeedbackAndVisionTests.swift` (3 assertions updated).
Files edited (docs, strike/update): `docs/TESTING.md` (logs claim corrected + new "Headless tests" section), `AGENTS.md` (command table +3 rows).
Bug found by the on-phone test: `.normal` speech is skipped while the voice is busy, so "You have arrived at Room 204." was never spoken (it arrived while "Continue straight." was talking). Fixed by making arrival/turn/hazard speech `.high`
  (interrupts); re-ran on the phone: arrival now spoken. Also found while building the test: my first harness picked `maps.first` (alphabetical), which was U1's own scan, so it failed with exit 2; now it searches all maps.
Observed state: the phone already holds 2 maps (the seeded SAMPLE map and a map saved by U1 - name "Rice Hall, floor 1"), i.e. U1 has already saved at least one scan (U1.5 partly done; relocalization U1.6 still unmeasured).
Verified ON DEVICE (iPhone 16 Pro Max, iOS 27, USB, unlocked): `make selftest-sim` -> instruction changes continueStraight -> turnRight(57 deg) -> continueStraight -> arrived; `say:` lines incl. arrival; `haptic: turnRight`, `haptic: arrived` (no haptic errors);
  `spatial audio started` (no audio errors); beacon local x=+1.50 (to the right) at the right turn; `SELFTEST PASS`, exit 0. Also `make test` 50 pass, `make typecheck` OK (20 app files), build succeeded and installed.
NOT verified: that the audio is actually audible/directional to a human (needs headphones + ears), that haptics are felt, `make selftest-scan` (not run yet), anything LiDAR/mesh/relocalization.
Open: U1 to run `make selftest-scan` while walking (U1.4). U2 owns tuning audio now that the walk is reproducible with one command.

---

## 2026-10-17 16:20 — Claude (agent, for Sachin) — U1.1 signing: certificate found, Team ID set, app built + installed on iPhone 16 Pro Max   [tags: BUILD]
Area: U1 (setup)
What happened: Sachin created the Apple Development certificate in Xcode (Personal Team, certificate under khanalsachin@icloud.com). Read the real team id from the certificate OU
  (5S33HP2CPC) and wrote `DEVELOPMENT_TEAM` and `WAYPOINT_DEV_SUFFIX = sachin` into the git-ignored `Config/Local.xcconfig`.
Doc bug found and fixed: our instructions said the team id is the "(XXXXXXXXXX)" in `security find-identity`; that value is a certificate/person id (here YN84BMTT4S) and is NOT the team id.
  Added `scripts/team-id.sh` + `make team-id`; corrected `Config/Local.xcconfig.example` (comment) and `docs/SETUP.md` (old text struck through, labelled Update).
Verified (real device, not simulated):
- `make doctor` all PASS, phone `connected`, Developer Mode Enabled (queried via devicectl).
- `DEVICE=00008140-000914590E01801C make build` -> BUILD SUCCEEDED, signed with "Apple Development: khanalsachin@icloud.com", profile "iOS Team Provisioning Profile: io.github.sachin-khanal.waypoint.sachin".
- `make install` -> "App installed", bundleID io.github.sachin-khanal.waypoint.sachin.
NOT yet verified: launching. `make launch` was denied by iOS (error: "profile has not been explicitly trusted by the user"). Expected for free profiles: the developer must be trusted once on the phone
  (Settings > General > VPN & Device Management > Apple Development: khanalsachin@icloud.com > Trust). After that U1.1 is done when the app opens and camera + local network prompts are accepted.
Note for U2-U4: use `make team-id` for your own team id; each person's Apple ID gets its own id.

---

## 2026-10-17 15:40 — Claude (agent, for Sachin) — Bundle id prefix changed from edu.virginia.* to io.github.sachin-khanal.waypoint   [tags: BUILD, CONTRACT CHANGE]
Area: shared (U1 asked while doing U1.1 signing)
Why: I had used a UVA domain for bundle ids without asking; the team does not own or represent that domain. See D-019.
Files edited (code/config): `Config/Base.xcconfig` (+`WAYPOINT_BUNDLE_PREFIX`), `project.yml` (`bundleIdPrefix`, `PRODUCT_BUNDLE_IDENTIFIER` now uses the variable),
  `Makefile` (reads the prefix from xcconfig), `scripts/doctor.sh`, `Waypoint/App/Log.swift` (logger subsystem), `Package/.../Cloud/CloudModels.swift` (Keychain service),
  `Package/.../Tests/.../CloudTests.swift`, `Config/Local.xcconfig.example` (comment).
Files edited (docs, strike-through + Update): `Architecture.md` (setup checklist), `docs/SETUP.md` (troubleshooting row), `docs/TESTING.md` (log subsystem); `docs/DECISIONS.md` (+D-019).
Effect for everyone: final bundle id is `io.github.sachin-khanal.waypoint.<WAYPOINT_DEV_SUFFIX>` (e.g. ...waypoint.sachin). Nothing else to do except pick a suffix in your `Config/Local.xcconfig`.
  Anyone who had already installed a build would now see it as a different app (nobody had).
Verified: `make test` -> 50 tests, 0 failures; `make typecheck` OK; `make check` -> BUILD SUCCEEDED; built Info.plist CFBundleIdentifier = `io.github.sachin-khanal.waypoint.<suffix from Local.xcconfig>` (it showed the unedited placeholder suffix `replacewithyourname`, so set a real suffix); `make doctor` shows the new prefix.
NOT verified: signing/installing with the new id (no signing identity exists on this Mac yet; U1.1 in progress).

---

## 2026-10-17 15:10 — Claude (agent, for Sachin) — Detailed per-person roadmap (Revision 3)   [tags: DOCS]
Area: shared (docs only, no code, tests not re-run)
Request: "make a roadmap with explicit granular details from start to finish, what we have so far, and what is attributed to each user" with the real team: U1 Mac Pro + iPhone 16 Pro Max, U2 Mac Air + iPhone Pro, U3 Windows + iPhone Pro, U4 Windows + regular iPhone.
Files edited (strike-through + Update rule respected, nothing deleted):
- `docs/ROADMAP.md` — old per-letter "Recommended assignment" struck through with a pointer; appended **Revision 3**: device capability matrix, state-of-the-project table, phases P0-P6 with gates G1-G5 and the critical path,
  full task tables for U1-U4 (ID, estimate, blocked-by, done-when), dependency sketch, branch/merge rules, check-in rhythm, cut order with owners, open questions.
- `AGENTS.md` (Human team) and `docs/MODULES.md` (team line): struck the "fill in names" placeholders, added the U1-U4 mapping (A=U1, B=U2, C=U2+U3, D=U2+U3+U4).
Assumptions to confirm: about 24 h remain; U3/U4 cannot build iOS so they get backend/web/tooling and field/QA/demo lanes (Swift changes via Live Share on a Mac host); the regular iPhone has no LiDAR, so no scanning or obstacle detection there.
New task IDs introduced: INF-1 (`make ipa` + sideload path), INF-2 (CI workflow); both unbuilt.
Verified: nothing to run (docs). Open: see "Open questions" at the end of Revision 3.

---

## 2026-10-17 14:40 — Claude (agent, for Sachin) — Security fixes: unsafe segment ids (path traversal) + Keychain session   [tags: BUG, CONTRACT CHANGE]
Area: D (cloud/sync) + shared Model
Trigger: automated commit-time security review, 2 findings (both MEDIUM, both judged valid):
1. Path traversal: `segmentId` from untrusted maps flowed into the Storage download path AND, worse than reported, into the LOCAL file name in
   `MapStore` (`worldmap-<segmentId>.arworldmap`) - a hostile map/bundle could write outside its folder.
2. Session tokens were stored in UserDefaults.
Files edited (code):
- `Model/MapTypes.swift` (+`SegmentID.isValid`: `[A-Za-z0-9_-]`, 1-64 bytes).
- `Model/MapStore.swift` (`MapBundle.validate()` checks node segment ids and world-map keys; `saveWorldMap`/`loadWorldMap` refuse unsafe ids).
- `Cloud/SyncEngine.swift` (`worldMapPath` now `throws` and requires a safe segment + UUID owner; `push`/`fetchBundle` updated; `fetchBundle` validates the
  map before any URL is built).
- `Cloud/CloudModels.swift` (`UserDefaultsSessionStore` REMOVED, `KeychainSessionStore` added: generic password, AfterFirstUnlockThisDeviceOnly; `import Security`).
- `Waypoint/Cloud/CloudController.swift` (uses `KeychainSessionStore`).
Tests added (+5, total 50): `testSegmentIdAlphabet`, `testValidationRejectsPathTraversalSegments`, `testStoreNeverWritesOutsideItsFolderForHostileSegments`,
  `testHostileSegmentIdNeverReachesAURL` (asserts zero /storage/ requests), `testKeychainSessionStoreRoundTrip` (skips itself if no keychain).
Docs (strike-through + Update per the new markdown rule): `docs/DECISIONS.md` (D-015 update, new D-018), `Architecture.md` §10.3 notes.
Contract note: `MapNode.segmentId` values outside the safe alphabet are now rejected on import/push. Maps created by the app use "seg1" and are unaffected.
Verified: `make test` -> 50 tests, 0 failures (Keychain test executed, not skipped); `make typecheck` OK; `make check` -> BUILD SUCCEEDED.
NOT verified: Keychain behaviour on a real iPhone (the code path is the standard Security API; test ran on macOS); nothing against a live Supabase project.
Open: a sideloaded free-profile build can use the Keychain without extra entitlements, but if a device ever reports a keychain error the app simply
re-signs-in anonymously (new user id), it does not crash. Anonymous users that lose their session cannot see their old private rows - acceptable for the demo, note for D.

---

## 2026-10-17 14:10 — Claude (agent, for Sachin) — New markdown rule + stale-docs pass (strike-through + labelled updates)   [tags: DOCS]
Area: shared (docs only; NO code changed, so tests/typecheck were not re-run)
Trigger: team rule: "for changes in markdown files, don't overwrite/delete — strike through the old text and add the new text (label updates)". Does not apply to code.
Files edited (all additive or strike-through; nothing deleted):
- `AGENTS.md` — new hard rule 11 (the convention, exceptions, how to handle tables/headings/code blocks/WORKLOG) + pointer to ROADMAP/TESTING in "Orient yourself".
- `docs/WORKFLOW.md` — principle 6 (same rule).
- `Architecture.md` — struck + updated: §1 constraint rows (no backend / Multipeer), §2 note (cloud, simulator), §3 note (Node/Edge -> MapNode/MapEdge),
  §4.7 note (cloud primary, Multipeer fallback, approvals), §5 note (original layout lines restored from git commit 370d66f as struck text), §6 owners/timeline notes,
  §7 four new risk rows + nice-to-have line, §9 three new open decisions, §10 heading/status ("PROPOSED" struck -> IN PROGRESS), new §10.5 implementation-status table.
- `docs/DECISIONS.md` — D-007 amended note; D-013..D-016 "PROPOSED" struck with labelled status updates (D-014 flagged as "REST was my default, not explicitly confirmed");
  new D-017 recording the markdown rule.
- `docs/ROADMAP.md` — header status struck/updated; new "status after build block 1" table; "start right now" items marked done.
- `docs/MODULES.md` — update note under the legend; "backlog additions after build block 1" per owner appended.
- `README.md` — "no server" sentence struck + updated; repo map gains `supabase/`; status paragraph gets a block-1 update.
- `docs/SETUP.md` — CoreSimulator known issue marked resolved on Sachin's Mac.
Not changed on purpose: older WORKLOG entries (history; they remain accurate for their time), `docs/TESTING.md` (new today).
Known imperfection: earlier today I overwrote a few numeric strings in place before this rule existed (test counts 25/27 -> 45 in README.md and docs/SETUP.md). They are plain count corrections; git history holds the old values.
Verified: grep shows each struck phrase still present next to its labelled update; `git diff --stat` touches only `.md` files in this pass.
Open: none new. If you want the old counts restored as struck text too, say so.

---

## 2026-10-17 — Claude (agent, for U3) — New Scanner + Navigator interface, mock-first (behind a default-OFF switch)   [tags: BUILD]
Area: shared (UI). Branch `app-ui-workflows`. Implements docs/UI_PLAN.md §2-§9; status and deviations in UI_PLAN §13.
Files created - WaypointCore (pure, with tests):
- `Flows/ScanFlow.swift` (ScanFlow, ScanQuality, ScanTracking.from(summary:), FinishGate), `Flows/NavigateFlow.swift`
  (NavigateFlow, defaultStart), `Flows/GuidanceState.swift` (GuidancePhase, GuidanceSnapshot, parse/derive of
  NavigationController strings), `Flows/RouteSummary.swift`, `Flows/MapHealth.swift`, `Flows/PlanLayout.swift`,
  `Flows/SpokenText.swift`; `Tests/WaypointCoreTests/FlowTests.swift` (21 tests).
Files created - app:
- `Waypoint/Services/`: ServiceMode (settings keys, factory, LiDAR check), ScanService + MockScanService + LiveScanService,
  GuidanceService + MockGuidanceService + LiveGuidanceService, Announcer (VoiceOver / spoken prompts, headphone check).
- `Waypoint/UI/DesignSystem/`: Theme, HeroButton, CardRow, MockBadge, StatusPill, QualityRing, Banner, TagPalette,
  PlanView, HoldToConfirmButton.
- `Waypoint/UI/Scanner/`: ScannerFlowView, ScanSessionModel, ScanLibraryView, ScanSetupView, LiveScanScreen,
  ScanReviewView, ScanShareView, MockCameraView.
- `Waypoint/UI/Navigator/`: NavigatorFlowView (+NavScreen, NavInfoRow), NavigatorModel (+Recents), BuildingPickerView,
  DestinationPickerView, RouteConfirmView, LocalizingView, GuidingView, ArrivedView, EscortPanel.
- `Waypoint/UI/SettingsView.swift`.
Files edited:
- `Waypoint/UI/RootView.swift` (owner D): gear button -> SettingsView; `ui.newInterface` (default false = Classic shows
  VolunteerView/NavigatorView exactly as before); optional open-in-Navigate on launch (new interface only).
- Docs (appended only): `docs/UI_PLAN.md` §13, `docs/MODULES.md` (3 rows), `docs/TESTING.md` (Level 4), this entry.
NOT edited (by design, UI_PLAN R1/R3): CaptureController, NavigationController, Relocalizer, LiveScanView, guides, MapSync,
  CloudController, VolunteerView, NavigatorView, SyncView, AppState, any existing WaypointCore file, project.yml.
Data contract: unchanged (no CONTRACT CHANGE). Renaming a place in Review re-saves map.json with version + 1.
Commands run:   none that compile (written on Windows: no Swift toolchain). Static review only.
Verified:       NOTHING COMPILED. Checked by reading: every new type defined once, no name clashes with existing app/core
  types, protocol conformances complete, memberwise-init argument orders, iOS 17 API availability, no `#Preview`
  macro (PreviewProvider used so plain `swiftc -typecheck` works). FlowTests expectations computed by hand from the
  sample map.
NOT verified:   `make test`, `make typecheck`, `make check` - must be run on a Mac first. Everything in Waypoint/ is
  UNVERIFIED ON DEVICE (VoiceOver flow, spoken prompts, live adapters, plan view, haptics).
Open problems / handoff:
1. A Mac owner: pull `app-ui-workflows`, run `make test && make typecheck`, fix any compile errors, log the result here.
2. U1 review `LiveScanService` mapping; U2 review `LiveGuidanceService` + Navigator accessibility (UI_PLAN §12 Q1).
3. Run TESTING Level 4 on phones (4.3 with VoiceOver and eyes closed is the important one).

## 2026-10-17 — Claude (agent, for U3) — UI plan for Scanner + Navigator workflows (mock-first)   [tags: DOCS]
Area: shared (UI). Branch `app-ui-workflows`.
Files created:  `docs/UI_PLAN.md` (plan only, no code).
Files edited:   `docs/WORKLOG.md` (this entry).
Files deleted:  none.
Commands run:   none (read-only review of the repo).
Verified:       n/a (documentation).
NOT verified:   nothing built yet.
Open problems / handoff: plan proposes new files only plus a default-off switch in `RootView`; needs answers to
  UI_PLAN.md §12 from U1/U2 (ownership of `Waypoint/UI/Navigator/`, RootView switch) before P1 starts.

## 2026-10-17 13:30 — Claude (agent, for Sachin) — Build block 1: live scanner, simulate mode, Supabase client + schema   [tags: BUILD, CONTRACT CHANGE]
Area: A (scan view), B (simulation), D (cloud), C (budget) - scaffolded together; owners should take over each part.
Why: user said "continue building" and to integrate Supabase while building (ROADMAP.md revision 2).

Files created - WaypointCore (all unit-tested):
- `Scan/OrientedBox.swift` (gravity-aligned box, yaw search, contains/corners/expanded), `Scan/ExportBudget.swift`
  (40 MB cap vs Supabase 50 MB/file limit).
- `Simulation/PoseSimulator.swift` (virtual walker that turns before walking).
- `Cloud/HTTPTransport.swift`, `Cloud/CloudModels.swift` (SupabaseConfig, AuthSession, SessionStore, BuildingRow,
  RemoteMap, CloudError), `Cloud/SupabaseClient.swift` (actor: anonymous auth + refresh + one 401 retry, PostgREST
  upsert/list, Storage upload/download; plain REST, no SDK), `Cloud/SyncEngine.swift` (push uploads world maps
  BEFORE the row; fetch validates).
- Tests: `ScanAndSimulationTests` (6), `CloudTests` (11, mock transport) -> **45 tests total**.
Files created - app (type-checked only): `Waypoint/Scan/MeshSampler.swift`, `Waypoint/Scan/LiveScanView.swift` (RealityKit
  ARView + `.showSceneUnderstanding` mesh overlay + green wireframe box), `Waypoint/Cloud/CloudController.swift`.
Files created - other: `supabase/migrations/0001_init.sql` (tables buildings/scans, RLS, private buckets
  worldmaps/meshes, storage policies, updated_at trigger), `docs/TESTING.md`.
Files edited:
- `Geometry/Geometry.swift` (+`cameraTransform(position:forward:)`).
- `Waypoint/Capture/CaptureController.swift` (meshWithClassification, ~1 Hz box fit, stats, `adjustBoxMargin`).
- `Waypoint/Navigation/NavigationController.swift` (REWRITTEN: shared `tick` loop driven by AR frames OR the simulator;
  `startSimulation`, `simulatedObstacle`).
- `Waypoint/UI/VolunteerView.swift` (full-screen live scan + HUD + box controls), `NavigatorView.swift` (Simulate section +
  obstacle toggle), `SyncView.swift` (Cloud section as its own observing view `CloudSection`).
- `Waypoint/App/AppState.swift` (+`cloud`), `project.yml` + `Config/Base.xcconfig` + `Config/Local.xcconfig.example`
  (SUPABASE_URL / SUPABASE_ANON_KEY -> Info.plist keys `SupabaseURL`/`SupabaseAnonKey`; empty = cloud disabled).
- Docs: `docs/SETUP.md` (+Supabase section §5), `docs/MODULES.md`, `README.md`.
Data contract: `BuildingRow`/table `buildings` is new (one row per owner+map_id; clients merge). `BuildingMap` unchanged.
Bugs found by tests while building: mock matched "/authenticated/" as "auth" (test bug); 401-retry test logic (test bug).
  One real review catch: SyncView did not observe CloudController (would not redraw) -> fixed with `CloudSection`.
Verified: `make test` -> **45 tests, 0 failures**; `make typecheck` OK (19 app files); `make check` (xcodebuild, unsigned) ->
  BUILD SUCCEEDED, no warnings.
NOT verified (UNVERIFIED ON DEVICE / vs real server): live mesh overlay and box on a phone; ARView sharing our ARSession
  (we rely on ARView NOT replacing the session delegate); mesh vertex reading layout; simulate-mode audio; every Supabase
  call against a real project (SQL never executed; Anonymous Sign-Ins must be enabled by a human); cloud UI.
Open / handoff:
1. Someone creates the Supabase project and follows SETUP.md §5, then runs TESTING.md level 2.9.
2. A: validate 3.1-3.5 in docs/TESTING.md; replace debug mesh overlay with per-anchor coloured entities; MeshExporter (USDZ) +
   viewer are NOT built yet (C).
3. B: TESTING.md 2.2-2.6 with headphones; tune cues.
4. Security note: nothing in the repo contains a Supabase key; never commit the service_role key.

---

## 2026-10-17 12:30 — Claude (agent, for Sachin) — Direction change: Supabase + Polycam-style scanner (docs only)   [tags: DOCS]
Area: shared
Trigger: user said the app is native-iPhone-only (not published), uses Supabase free tier, and needs a
live bounding-box -> 3D LiDAR scanner like Polycam.
Files created: `docs/ROADMAP.md` (workstreams 0-7, owners, milestones M0-M5, cut lines, tasks an agent
can start without a phone).
Files edited: `Architecture.md` (+section 10 "Revision 2", PROPOSED); `docs/DECISIONS.md` (+D-013..D-016, all
PROPOSED; D-016 amends D-007).
Code changed: none. No tests affected.
Verified: nothing to run (docs only).
Open: team must approve the proposals; then start stream 0 (device bring-up) and the phone-free tasks in
ROADMAP.md. Supabase project must be created by a human (needs their account); never commit the service-role key,
only the public anon key belongs in the app config.

---

## 2026-10-17 12:05 — Claude (agent, for Sachin) — xcodebuild now works; first full app build succeeds   [tags: BUILD]
Area: shared
Context: after the CoreSimulator fix (`sudo xcodebuild -runFirstLaunch`, run by Sachin), retried the build.
Files edited: `project.yml` (+`UIRequiresFullScreen: true` to silence the "all orientations" build
warning; app is portrait-only); `Waypoint/Info.plist` regenerated by `make gen`.
Verified: `make doctor` -> CoreSimulator PASS; `make check` (unsigned `xcodebuild`, generic iOS) ->
**BUILD SUCCEEDED**, no warnings after the orientation fix; `make test` -> 27 pass.
NOT verified: signing (`make build`/`run` need `Config/Local.xcconfig` + Apple ID, none set up on this
Mac yet), installing on a phone, and any runtime behaviour. No iPhone was connected.
Handoff: next step is SETUP.md section 3 (Apple ID, team id, Developer Mode, trust), then `DEVICE=<id> make run`.

---

## 2026-10-17 11:40 — Claude (agent, for Sachin) — Security fix for map sync (approval + validation)   [tags: BUG, CONTRACT CHANGE]
Area: D (Sync) + shared Model
Trigger: automated background security review flagged `MapSync.swift`: it auto-accepted every
Multipeer invitation and auto-imported any received map (MEDIUM, missing auth / untrusted import).
Judged valid: a hostile map could steer a blind user somewhere unsafe.
Files edited:
- `Package/WaypointCore/Sources/WaypointCore/Model/MapStore.swift` — added `MapStoreError.rejected`,
  `MapBundle.validate()` (limits, finite positions, unique ids, edges reference nodes, distance vs
  geometry), `importBundle` now validates and refuses NEW edges between two already-known nodes when
  merging. `import simd` added.
- `Waypoint/Sync/MapSync.swift` — invitations held in `pendingInvitation` until
  `respondToInvitation`; received files are size-checked, decoded, validated, then held in
  `pendingMap` until `respondToIncomingMap(accept:)`; nothing touches disk before approval.
- `Waypoint/UI/SyncView.swift` — two alerts: "Connect to <phone>?" and "Import this map?" (shows name,
  sender, node/edge counts).
- `Package/WaypointCore/Tests/WaypointCoreTests/ModelTests.swift` — +2 tests
  (`testValidationRejectsHostileBundles`, `testImportRefusesNewEdgeBetweenExistingNodes`); `import simd`.
- `docs/DECISIONS.md` (D-012), `README.md` and `docs/SETUP.md` (test count 25 -> 27).
Verified: `make test` -> **27 tests, 0 failures**; `make typecheck` -> OK (16 app files).
NOT verified: **UNVERIFIED ON DEVICE** - the alerts and Multipeer flow have never run on phones.
Known limits / handoff:
- Multipeer has no strong peer identity; the human approval is the control. A pairing code in the
  invitation context would be a stronger, optional upgrade (D).
- Loop-closing between two existing nodes is blocked on merge (documented in D-012).
- The AirDrop/Files import path has no UI yet; when D adds an "open .waypointmap" handler it must
  show the same approval step before calling `importBundle` (which validates but does not ask).

---

## 2026-10-17 11:15 — Claude (agent, for Sachin) — Initial scaffold of the whole project   [tags: BUILD, DOCS, CONTRACT CHANGE]
Area: shared (all four areas scaffolded; nothing here was written by A/B/C/D individually yet)

**Why:** team has 24 hours, 4 people, free Apple ID signing, Live Share and/or git (undecided);
wanted a CLI-first build and docs readable by humans and agents.

### Tooling installed on this Mac
- `brew install xcodegen` (v2.46.0). Nothing else installed. No sudo used.

### Files created — build system and config
- `project.yml` — XcodeGen spec: app target `Waypoint` (iPhone only, iOS 17, Swift 5 mode), local
  package dependency `WaypointCore`, Info.plist keys (camera, local network + Bonjour
  `_waypoint-map._tcp/_udp`, arkit capability, Files-app sharing), bundles `Samples/` as resources.
- `Config/Base.xcconfig` — defaults + optional `#include? Local.xcconfig`.
- `Config/Local.xcconfig.example` — template for per-developer team id + bundle suffix.
- `Makefile` — targets: help, setup, doctor, gen, test, typecheck, check, build, install, launch,
  run, logs, devices, open, clean, clean-all. Builds into `~/Library/Caches/Waypoint` (D-005).
- `scripts/doctor.sh` — machine diagnostics. `scripts/typecheck.sh` — builds WaypointCore for the
  iOS SDK and `swiftc -typecheck`s the whole app without xcodebuild.
- `.gitignore` — ignores `*.xcodeproj`, `Config/Local.xcconfig`, build dirs, `.DS_Store`.
- `Waypoint/Info.plist` — GENERATED by XcodeGen from `project.yml` (edit the yml, not this file).

### Files created — docs
- `AGENTS.md` (rules for agents/humans), `CLAUDE.md` (imports AGENTS.md), `docs/SETUP.md`,
  `docs/WORKFLOW.md` (Live Share vs git), `docs/MODULES.md` (ownership/status/interfaces),
  `docs/DECISIONS.md` (D-001..D-011), this file. `README.md` rewritten (was one line).
- `Architecture.md` (created earlier in the session) edited: type names, repo layout, build system.

### Files created — `Package/WaypointCore` (pure logic, tested; no Apple UI/AR frameworks)
- `Package.swift` — SwiftPM manifest (iOS 17 + macOS 14 so `swift test` runs on the Mac).
- `Model/MapTypes.swift` — `NodeKind`, `Hazard`, `MapNode`, `MapEdge`, `MarkerRef`.
- `Model/BuildingMap.swift` — the map document, JSON helpers, `merged(with:)` (union by id,
  local copy wins, version = max+1), `destinations`, `segmentIds`.
- `Model/MapStore.swift` — disk layout `<Documents>/Maps/<uuid>/map.json` + `worldmap-<seg>.arworldmap`;
  `MapBundle` (+ `.waypointmap` export file, import-with-merge).
- `Model/MapBuilder.swift` — breadcrumb every 1.5 m + POI nodes attached to last breadcrumb.
- `Geometry/Geometry.swift` — point/direction transforms, `signedBearing` (right = positive),
  `rotationY`, marker -> `mapToWorldTransform`.
- `Routing/WaypointGraph.swift`, `Router.swift` (A*, stairs penalty 1000 unless allowed),
  `GuidanceInstruction.swift`, `RouteFollower.swift` (advance within 1 m; straight < 25°, turn-around > 135°).
- `Guidance/FeedbackPlanner.swift` — priority/de-dupe rules producing `speak/haptic/beacon` actions.
- `Vision/ObstacleClassifier.swift` — stop <0.6 m, caution <1.2 m, 0.15 m hysteresis.
- `Vision/RoomNumberParser.swift` — `\b\d{3}[A-Z]?\b` extraction + `ConsensusFilter` (3 reads).
- Tests: `ModelTests` (5), `RoutingTests` (13), `FeedbackAndVisionTests` (7) = **25 tests**.

### Files created — iOS app target `Waypoint/` (needs a phone)
- `App/WaypointApp.swift`, `App/AppState.swift` (seeds the sample map on first launch), `App/Log.swift`.
- `UI/RootView.swift`, `UI/VolunteerView.swift`, `UI/NavigatorView.swift`, `UI/SyncView.swift`.
- `Capture/CaptureController.swift` (ARSession + LiDAR mesh, breadcrumbs, POI tag, save ARWorldMap).
- `Relocalization/Relocalizer.swift` (initialWorldMap + optional marker fallback).
- `Navigation/NavigationController.swift` (per-frame integration loop).
- `Guidance/SpatialAudioGuide.swift` (AVAudioEnvironmentNode ping), `HapticsGuide.swift`
  (CoreHaptics: 1 tap = left, 2 = right), `SpeechGuide.swift`.
- `Vision/ObstacleDetector.swift` (LiDAR depth region min), `Vision/SignReader.swift` (Vision OCR, NOT wired in).
- `Sync/MapSync.swift` (MultipeerConnectivity, `sendResource` of `.waypointmap`).
- `Samples/rice-hall-sample.json` — HAND-WRITTEN fake corridor with Room 204/206, stairs, door.
  It is test data, not a real scan of Rice Hall.

### Commands run and results
- `swift test` (default build dir inside repo) -> compiled, then **FAILED at codesign**:
  `resource fork, Finder information, or similar detritus not allowed`. Cause: repo is under
  iCloud-synced `~/Desktop`. Fix: build outside the repo (D-005). Stray `.build` dir deleted.
- `make test` -> **25 tests, 0 failures**.
- `make typecheck` -> **OK, 16 app files** (builds WaypointCore for the iPhoneOS 27.1 SDK, then
  type-checks every app file; no errors or warnings).
- `make gen` -> generates `Waypoint.xcodeproj` successfully.
- `make check` (xcodebuild) -> **FAILS on this Mac before compiling anything**:
  `IDESimulatorFoundation ... CoreSimulator.framework ... no such file` ("A required plugin
  failed to load"). Needs `sudo xcodebuild -runFirstLaunch` by a human (not run by the agent).
  Also `xcrun simctl` is unusable for the same reason. `make doctor` now flags this.
- `make doctor` -> works; no devices connected, no `Local.xcconfig` yet, no signing identity yet.

### NOT verified (important)
- **UNVERIFIED ON DEVICE:** everything under `Waypoint/` at runtime — ARKit capture, world-map
  save/relocalize, marker fallback, LiDAR depth read, spatial audio, haptics, speech, OCR,
  Multipeer sync, all screens. It type-checks against the iOS SDK; it has never run.
- **Never built with xcodebuild or signed.** Signing flow in `docs/SETUP.md` is unexercised.
- Depth-region orientation, audio coordinate handling, and the marker yaw convention are
  best-effort and flagged with TODOs in the file headers.

### Open problems / handoff
1. Someone with admin rights must run `sudo xcodebuild -runFirstLaunch` on each Mac (see SETUP.md).
2. Each dev: `make setup`, fill `Config/Local.xcconfig`, do the one-time Xcode signing run (SETUP.md §3).
3. First integration target: install on a Pro iPhone, choose Navigate -> the seeded SAMPLE map ->
   confirm the app launches and permission prompts appear. (Navigation on the sample map cannot
   relocalize without a real world map; it will sit in "Looking for your position" until A's
   scan/marker path works. B/C can still test audio/haptics/obstacles by temporarily feeding fake poses.)
4. Fill in team names in `docs/MODULES.md`; decide Live Share vs git (`docs/WORKFLOW.md`).
5. Known logic gaps are listed per owner at the bottom of `docs/MODULES.md`.
