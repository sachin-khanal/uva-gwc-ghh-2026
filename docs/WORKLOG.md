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
