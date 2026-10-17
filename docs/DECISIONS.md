# Decisions log

**Update 2026-10-17 (Codex, user-directed):** D-015's contributor-copy approach is superseded for updated clients by one canonical shared map per building UUID. Migration 0002 adds canonical_buildings and an atomic additive extension RPC. Signed-in users can see and extend it; private publication is removed from the cloud UI. Existing records/data remain in place for old clients. See `supabase/CANONICAL_MAPS.md` for deployment, identity, and verification limits. This cloud change is UNVERIFIED on live Supabase and iOS; full scan-extension capture remains separate.

Short ADRs. Add new ones at the bottom with the next id. Do not rewrite history; supersede instead.

## D-001 — Native iOS, Swift + SwiftUI, iOS 17+
ARKit world maps, LiDAR depth, Vision OCR, CoreHaptics, spatial audio all run on-device with no
setup. Cross-platform stacks add a bridge per framework. **Status:** accepted.

## D-002 — Free Apple ID signing, no paid profile
Constraint given by the team. Consequences: 7-day app expiry, 3 apps per phone, no TestFlight/
iCloud/push. Each dev uses their own team id and unique bundle id via `Config/Local.xcconfig`.
**Status:** accepted.

## D-003 — Zero third-party dependencies
Fewer moving parts, no package resolution failures offline at the venue. Only Apple frameworks.
(XcodeGen is a dev tool, not an app dependency.) **Status:** accepted.

## D-004 — XcodeGen + CLI workflow; `.xcodeproj` is generated and git-ignored
Removes `.pbxproj` merge conflicts for 4 people and lets agents/CLI build. Source of truth:
`project.yml`. Supersedes the "Xcode 16 synchronized folders" idea in the first Architecture draft.
**Status:** accepted.

## D-005 — Build output lives in `~/Library/Caches/Waypoint`, not in the repo
The repo sits in `~/Desktop` (iCloud-synced). Files there acquire Finder metadata and `codesign`
fails with "resource fork, Finder information, or similar detritus not allowed". Observed
2026-10-17 when running `swift test` with the default `.build` directory. The Makefile passes
`-derivedDataPath` / `--scratch-path` outside the repo. **Status:** accepted.

## D-006 — Pure logic lives in a Swift package (`WaypointCore`) tested on macOS
The Simulator runtime is not installed on our Macs and ARKit/LiDAR need hardware, so anything that
can be proven without a phone is put in `Package/WaypointCore` and covered by `make test`
(runs in seconds). The app target only holds platform glue. **Status:** accepted.

## D-007 — Sync via MultipeerConnectivity, AirDrop/share-sheet export as fallback
Campus Wi-Fi often isolates clients; Multipeer can use Bluetooth/peer-to-peer Wi-Fi and needs no
server or signing entitlements. **Status:** accepted; unverified on devices.
**Update 2026-10-17:** amended by D-016 — Multipeer is no longer the primary sync path; Supabase is. Multipeer/AirDrop remain as the offline fallback, and incoming peers/maps now need a user tap (D-012).

## D-008 — Map = JSON graph + ARWorldMap per segment; QR/image marker as relocalization fallback
ARWorldMap relocalization is the highest risk. We keep short segments and a marker fallback.
See Architecture.md section 4.2. **Status:** accepted.

## D-009 — Swift 5 language mode
Swift 6 strict concurrency would cost time without benefit in 24 hours. ARKit delegates run on the
main queue, which the code relies on (documented in file headers). **Status:** accepted.

## D-010 — Model type names are `MapNode` / `MapEdge` (not `Node` / `Edge`)
Avoids clashes with SwiftUI/other `Node` types. Architecture.md section 3 was updated to match.
**Status:** accepted.

## D-011 — Haptic direction encoded by pattern, not by side
iPhone has a single Taptic Engine. Left = 1 sharp tap, right = 2 sharp taps. Must be explained to
the demo user. **Status:** accepted.

## D-012 — Map sync requires user approval and validates incoming data
Raised by an automated security review of `MapSync.swift` (2026-10-17). A map is safety-critical:
a malicious or corrupt one could route a blind user into stairs or hazards. So: (1) incoming
Multipeer connection requests need an explicit tap; (2) incoming maps are decoded and run through
`MapBundle.validate()` (size limits, finite positions, unique ids, edges reference real nodes, edge
distance within max(0.5 m, 25%) of node geometry), then held until the user taps Import; (3) when
merging into an existing map, new edges between two already-known nodes are refused (blocks
spliced shortcuts; also blocks legit loop-closing - scan a node in between). Not covered:
authenticating WHO sent the map (Multipeer has no strong identity; the human check is the
control) and detecting a fully-formed but false map from an approved peer. **Status:** accepted.

## D-013 — Polycam-style live LiDAR scanner is part of volunteer mode (~~PROPOSED~~ ACCEPTED 2026-10-17)
Live mesh overlay + resizable bounding box + exported 3D model, using ARKit mesh reconstruction with
classification. Navigation remains the demo's climax; the scanner produces the map and the visuals.
Not in scope: photogrammetry, measuring, floor plans, public explore feed. ~~**Status:** proposed, awaiting team OK.~~
**Update 2026-10-17:** accepted — the user asked for a live bounding-box -> 3D LiDAR scanner and to keep building. Live view + box scaffolded (UNVERIFIED ON DEVICE); export/viewer not built.

## D-014 — Supabase over plain REST, no Supabase SDK (~~PROPOSED~~ IN USE, not explicitly confirmed)
Supersedes the "no backend" assumption for sync. We call PostgREST/Storage/GoTrue with `URLSession`
to keep D-003 (zero third-party dependencies) and to unit-test the client with a mock transport.
Trade-off: more code than `supabase-swift`. Revisit if the client takes more than ~3 hours.
~~**Status:** proposed.~~
**Update 2026-10-17:** Supabase itself was confirmed by the user; the REST-vs-SDK choice was my default and is implemented (`Cloud/`, 11 mock-server tests). Say so if you prefer the SDK.

## D-015 — Anonymous auth + Row Level Security; cloud data is untrusted (~~PROPOSED~~ IMPLEMENTED 2026-10-17, unverified on a live project)
No signup flow in a 24h demo. The anon key is public, so RLS is the only authorization. Downloaded
maps are validated and user-approved exactly like peer-to-peer imports (D-012). ~~**Status:** proposed.~~
**Update 2026-10-17:** implemented in `supabase/migrations/0001_init.sql` and `SyncEngine`/`CloudController` (other people's maps need a tap; everything is validated). The SQL has never been run on a real project.
**Update 2026-10-17:** hardened by D-018 — segment ids are restricted to a safe alphabet, and the session token is stored in the Keychain (~~UserDefaults~~).

## D-016 — Multipeer/AirDrop stay as the offline fallback (~~PROPOSED~~ IMPLEMENTED 2026-10-17)
Venue Wi-Fi may be bad or the free-tier project may be paused. Navigation never depends on the network.
Amends D-007: Multipeer is no longer the primary sync path. ~~**Status:** proposed.~~
**Update 2026-10-17:** implemented — Multipeer + AirDrop export are unchanged and still work; the Cloud library is added beside them in Share maps.

## D-017 — Markdown changes are strike-through + labelled updates, never overwrites (2026-10-17)
Rule from the team: when a `.md` file goes stale, keep the old text ~~struck through~~ and add the new text labelled
`**Update YYYY-MM-DD (who):**`; do not delete or overwrite. Applies to markdown only; code is exempt (git is its history).
Codified as AGENTS.md rule 11 and docs/WORKFLOW.md principle 6. This pass applied it to Architecture.md, DECISIONS.md, ROADMAP.md,
MODULES.md, README.md and SETUP.md (see WORKLOG). Earlier edits that overwrote text were restored as struck-out text from git
where the original was recoverable (Architecture.md §3, §5). **Status:** accepted.

## D-018 — Untrusted ids never become paths; credentials live in the Keychain (2026-10-17)
Raised by a commit-time automated security review. (1) `segmentId` comes from map data written by other people yet became a local
file name (`worldmap-<id>.arworldmap`) and a Storage path. A value like `../../x` could have written outside the map folder or
steered a download URL. Now ids must match `[A-Za-z0-9_-]{1,64}` (`SegmentID.isValid`), enforced in `MapBundle.validate()`,
`MapStore.saveWorldMap/loadWorldMap`, and `SyncEngine.worldMapPath` (which also requires a UUID owner); `fetchBundle` validates the
whole map BEFORE building any URL. (2) The Supabase access/refresh tokens were stored in UserDefaults; they now live in the Keychain
(`KeychainSessionStore`: generic password, accessible after first unlock, this device only). The anon key is public by design and
stays in Info.plist. **Status:** accepted; covered by tests (traversal attempts, Keychain round trip).

## D-019 — Bundle ids use `io.github.sachin-khanal.waypoint.<suffix>`, not a university domain (2026-10-17)
The first scaffold used `edu.virginia.waypoint` because the hackathon is UVA-hosted. That namespaces our app under a domain nobody on the team
owns or represents, so it was wrong to assume. A bundle id is only a unique label (nothing contacts it, free signing does not verify it), but it should
not claim an institution. We use the GitHub-pages convention `io.github.<github-user>`: prefix `io.github.sachin-khanal.waypoint`, final id `io.github.sachin-khanal.waypoint.<suffix>` where the
suffix is per developer (`WAYPOINT_DEV_SUFFIX` in `Config/Local.xcconfig`) so free Apple IDs do not collide. The prefix is now ONE setting
(`WAYPOINT_BUNDLE_PREFIX` in `Config/Base.xcconfig`) read by `project.yml`, the Makefile and `scripts/doctor.sh`. The Swift logger subsystem and Keychain
service name use the same prefix as constants. Changed before anyone had installed the app, so no migration is needed. If the repo ever moves to another
GitHub account, change the prefix in `Config/Base.xcconfig`, `project.yml` (`bundleIdPrefix`), `Log.swift` and `CloudModels.swift`. **Status:** accepted.

## D-020 — Performance changes must be lossless; measure before and after (2026-10-17)
U1 reported lag in the live scan view. Rule adopted: an optimisation may remove work that produces nothing we store or use, move work off the main thread, or replace an algorithm with an
EXACT equivalent; it may not shrink or degrade the saved map, the ARWorldMap, or the mesh data. Applied: (1) exact box fit via convex hull (equality with the brute-force fit is a unit test on 60 random clouds), reading
ALL vertices instead of every 6th, on a background queue, never overlapping; (2) HUD properties only publish real changes (was ~60 SwiftUI re-renders/s for nothing); (3) plane detection off (no code uses plane anchors; relocalization uses
feature points, not planes); (4) ~~per-face classification off by default (nothing reads it yet) - NOT lossless for the future colouring/door-suggestion features, which must switch it on with `-scanClassification YES` or a UI setting;~~ **Update 2026-10-17 (team decision "keep lossless"):** classification is **ON by default** for scans we keep, because a scan recorded without it can never get wall/floor/door labels afterwards (information lost at capture time is lost for good). It is switchable per scan on the start screen ("Record surface labels", id `scan.labels`) or with `-scanClassification NO` for quick tests and lag A/B runs;
(5) unused RealityKit post-processing disabled; (6) mesh overlay is a switch (`-scanOverlay NO` or the toggle on the scan screen) - mapping and saved data are identical with it off, only the on-screen drawing changes.
Not done because NOT lossless: lower camera resolution/frame rate (could hurt tracking and relocalization), decimating or dropping mesh anchors, lowering mesh refresh. Also: day-to-day `make run` builds **Debug** (unoptimised Swift is often many times slower in tight loops);
use `CONFIG=Release make run` for any performance judgement. **Status:** accepted; the real-world effect is UNMEASURED until someone runs it on a phone in a real room (see docs/TESTING.md, "Measuring scan performance").

## D-021 — Lossless-first policy for scanning; the lossy vector layer is NOT being built now (2026-10-17)
Decision (U1): keep everything lossless. In practice: (a) capture records the maximum we can use later (surface classification on by default; world map and graph unchanged); (b) every performance change must be exact or remove work whose output nothing consumes (D-020);
(c) the visual overlay stays ON by default (the volunteer needs to see coverage holes), with a switch for lag or demos; (d) the proposed "vector map" layer (planes + object boxes replacing triangles) is lossy by design and is **parked**: revisit only after gate G3 and only as an ADDITIONAL derived layer, never replacing raw capture data.
Reversibility rule of thumb: anything dropped at CAPTURE time is gone forever (classification, mesh detail); anything dropped at DISPLAY or at EXPORT time can be redone from the capture. So be generous at capture, thrifty at display. **Status:** accepted.

## D-022 — Accessibility-first guidance: posture coach, named obstacles, distance-aware instructions (2026-10-17)
Requirement from U1: this app is for visually impaired people, so (1) the phone must be held correctly and the user told when it is not; (2) instructions must be explicit and granular, and obstacles named by type.
Design: **Posture** - `PostureMonitor` (WaypointCore) reads pitch/roll from the camera pose; hysteresis (warn at 30 deg, clear below 20), dwell (0.8 s bad / 0.5 s good), repeat every 8 s, one "Phone position is good" on recovery; while wrong, route cues and the beacon are muted (the heading cannot be trusted)
but obstacle warnings stay on (a wall outranks the coaching). Distinct 3-tap haptic. **Obstacles** - `ObstacleKind` + `ObstacleReport`; kind from the labelled LiDAR mesh (wall/door/window/table/seat) first, then Apple Vision image classification of a crop around the hit
(`VNClassifyImageRequest`, no download; 1,303 labels on the test phone incl. `trash_can`, `chair`, `door`, `stairs`, `table`, `window`, `plant`); spoken at once as "obstacle" and upgraded when identified; low confidence is hedged ("Possibly a trash can directly ahead"), never stated as fact; STOP repeats every 3 s.
**Instructions** - route briefing ("Walk straight about 12 meters, then turn right."), countdown at 10/5/2 m ("In 5 meters, turn right."), the turn itself, landmarks ("Room 206 on your right."), arrival; distances in steps up close and meters further out. All wording is in `SpokenPhrases.swift` and asserted verbatim in tests so it can be reviewed by U4 and blind users.
**Camera-axis finding (a real bug):** ARKit's camera frame is fixed to the SENSOR. For an upright portrait phone camera +x points toward the BOTTOM of the phone and +y toward the user's RIGHT. The real-device audio beacon used camera-local x as "right", which is wrong in portrait (the simulation hid it because its fake camera used x = right). Fixed in one place: `Geometry.cameraTransform` now produces the real convention and
`Geometry.cameraLocalToUser` converts for the audio engine; the depth detector's corridor was also the wrong shape on a portrait phone and now unprojects to world points and ignores floor/ceiling (`ObstacleBand`). **All of this is derived from Apple's documented axes and proven only by synthetic poses: it MUST be confirmed on a real phone** (docs/TESTING.md, "Accessibility checks on a real phone").
Not done yet: side obstacles ("chair on your left" needs a left/right scan), stairs-down/ledge detection, low objects under 15 cm, temporal voting for object names, calibration of thresholds, blind-user review of the wording. **Status:** accepted; implemented; device behaviour UNVERIFIED.

## D-023 — One canonical shared map per building UUID; additive, atomic extensions (2026-10-17)
Recorded retroactively by Claude from the Codex/U3 WORKLOG entries; the decision was user-directed (U3).
**Decision:** the cloud keeps ONE record per building id (`canonical_buildings`). Anyone signed in can read it and extend it through the `extend_building` RPC, which merges atomically under an advisory lock. Extensions are additive: existing nodes and edges cannot be edited, and (migration 0003) a new edge joining two PRE-EXISTING nodes is rejected, matching the local `MapStore` import rule. `segment_owners` records which user contributed each scan segment so scan files from all contributors can be downloaded. The internal merge function has no API grants; only the checked wrapper is callable.
**Supersedes** for updated clients: the per-contributor copies of D-015 (kept for old-client data). `BuildingMap` JSON is unchanged (no schemaVersion bump).
**Consequences:** SETUP.md must run migrations 0001, 0002, 0003; different building names are NOT an identity mechanism; the capture side must keep segment ids unique and attach a new segment to an existing corridor/junction within 2 m / 0.75 m vertical (`MapBuilder`). Open: live concurrency and AR alignment across phones are unverified.

## D-024 — Docs are enforced on every commit: pre-commit hook + CI backstop (2026-10-17)
**Decision:** a commit that changes code must also add a new `docs/WORKLOG.md` entry (AGENTS.md rules 1 and 12). Enforced in three layers: (1) `scripts/githooks/pre-commit` -> `scripts/docs-sync.sh check`, activated per clone by `core.hooksPath` (`make hooks`, `make setup`, or automatically at Claude Code session start via `.claude/settings.json`); (2) `.github/workflows/docs-check.yml` re-checks pull requests and pushes to main, because local hooks can be skipped; (3) `make doctor` warns when the hook is missing.
**Why not auto-write the docs:** a hook cannot know what was verified on a device; invented text would be worse than none. So it blocks the omission, scaffolds the entry (`docs-sync.sh stub`, pre-filled with branch/author/changed files) and refuses leftover `<FILL: ...>` placeholders. It only ever appends to markdown, so rule 11 holds. Rule-11 rewrites, missing file headers, un-listed new files and `Model/*` edits without `CONTRACT CHANGE` are warnings, not blocks (typo fixes are legal).
**Limits (honest):** git hooks are not cloned, so each developer must install once (documented in AGENTS.md); agents that do not read `.claude/` (e.g. Codex) rely on AGENTS.md + the git hook; a determined `--no-verify` is only caught by CI. Docs-only commits are never blocked. No `make test` in the hook (needs a Mac, too slow).

> **Numbering note (2026-10-17):** the decisions below were written on a branch while D-023 and
> D-024 were taken on `main` for other decisions. They were renumbered +2 on merge (the old
> D-023..D-029 are now D-025..D-031); the content is unchanged.
## D-025 — Arrival outranks obstacle warnings, and the first route waits for the pose to settle (2026-10-17)
Both from testing on a phone (WORKLOG entry below this one).
1. **Arrival.** The destination is usually a thing you can walk into - a door - so the depth sensor sees it at STOP range
and `FeedbackPlanner` spoke "Stop. You are about to walk into a door." and `return`ed, which meant the arrival was never
announced at all. Arrival is now handled BEFORE obstacles: it is said once, the beacon is muted, and obstacle chatter is
suppressed from then on. Wording comes from the destination node's `NodeKind` (`ArrivalSpeech`), so it is general -
"You have arrived at Room 204. The door is right in front of you." / "...The stairs are right in front of you." /
"You have arrived at Room 204." for a plain room. This needed a **CONTRACT CHANGE**: `GuidanceInstruction.targetKind`
(optional, defaulted, so the JSON map format and every existing caller are unaffected).
2. **Start of the route.** `NavigationController` built its `RouteFollower` from the FIRST tick with tracking OK. Just
after relocalization the pose is still converging and often reads near the session origin - where the VOLUNTEER began
scanning - so the route was computed from there and walked the user back to the start of the scan before heading to the
destination. A new `StartGate` (pure logic, tested) requires N consecutive ticks within 0.35 m of each other before the
route may be computed. It is a race, which is why it was only seen once.
3. **Speech clipping.** One tick can emit several `.speak` actions and every `.high` one stops the synthesizer, so
earlier lines were cut off mid-word. `NavigationController.perform` now joins a tick's lines into one utterance at the
highest priority present. (This is NOT the separate dual-synthesizer problem on `app-ui-workflows`, where `Announcer`
and `SpeechGuide` own different `AVSpeechSynthesizer`s and genuinely talk over each other; that one is still open.)
**Status:** accepted; 91 tests pass. Arrival wording and the gate are UNVERIFIED ON DEVICE.

## D-026 — One voice: a single AVSpeechSynthesizer for the whole app (2026-10-17)
Reported on device: two voices speaking at once, worst at arrival. Cause: `SpeechGuide` (guidance) and `Announcer`
(the new UI) each owned an `AVSpeechSynthesizer`, and neither could see the other - SpeechGuide's "don't pile up"
check (`synthesizer.isSpeaking`) and Announcer's `stopSpeaking` each only applied to their own. At arrival both fired.
Fix: `Waypoint/Guidance/Speaker.swift` owns the only synthesizer in the app; `SpeechGuide` and `Announcer` keep their
APIs but forward to it. The decision rules (interrupt on `.high`, drop `.normal` while busy, drop identical text inside
a 3 s window) moved to `SpeechGate` in WaypointCore, where they are unit-tested - AVFoundation never runs in `make test`.
Deliberate trade-off: with VoiceOver running, `Announcer.say` no longer posts an `AccessibilityNotification.Announcement`.
That was a SECOND audio stream on top of the guidance voice. State changes are now spoken aloud in the app's voice in
both cases. VoiceOver still reads focused elements in its own voice (we do not control that), and sighted-scanner
chatter still goes to VoiceOver only via `Announcer.voiceOverOnly`. If a real VoiceOver user tests this and prefers
their own voice for state changes, the alternative is to route Announcer through VoiceOver ONLY while no guidance is
running - more code, revisit if someone asks for it.
Related but separate: a single tick emitting several `.speak` lines used to clip itself; that was fixed in D-025 by
coalescing them in `NavigationController.perform`.
**Status:** accepted; `SpeechGate` unit-tested (8 tests). The audible result is UNVERIFIED ON DEVICE.

## D-027 — Guide along the corridor, not along the volunteer's exact footsteps (2026-10-17)
Six findings from walking Rice Hall. All of them came from the same root idea being wrong: the app treated the
breadcrumb chain as the path to follow, rather than as a description of where it is possible to walk.
1. **Steering.** The follower classified the raw bearing to the NEXT breadcrumb (~1.5 m away) every tick with a single
25-degree threshold, so half a step sideways produced "go left, go right, turn around". It now aims at a point
`steeringLookaheadMeters` (3 m) further along the route - the corridor, not the footsteps - and classifies with
`HeadingCue`: a 45-degree deadband to START a turn, 22 to leave it (hysteresis), and a 3-tick debounce. The FIRST cue
is never debounced, so someone facing the wrong way is told immediately. The audio beacon is placed at the same
steering point, so the sound leads along the corridor instead of jumping between breadcrumbs.
2. **Loop closure.** `MapBuilder` linked each breadcrumb only to the previous one, so the map was a CHAIN, never a
graph. In a building with a central core the two ends of a loop are metres apart in space but dozens of nodes apart in
the graph, and A* sent the user the long way round the whole core. A new breadcrumb is now also linked to any older one
within `revisitRadius` (1.0 m) and at least `minChainSeparation` nodes back. **Safety:** we only join nodes the
volunteer PHYSICALLY STOOD AT, never by proximity alone - two corridors either side of a thin wall are close in space,
and joining them would route a blind user into the wall. There is a test for exactly that.
3. **Doors are the way IN.** A door in front of the room you asked for was announced as "Stop. You are about to walk
into a door.", leaving a blind user stranded outside their destination. `RouteFeature.isWayThrough` recognises when the
thing ahead IS what the route is taking us through (door -> room, door -> door, stairs -> stairs); it then gets caution
wording that says what to do ("The door to Room 204 is right ahead. You will need to open it to get in.") and guidance
CONTINUES instead of stopping dead. A wall, a chair or a person is still a full stop.
4. **Arrival depends on the kind of destination.** One fixed 1 m radius for everything. Now `ArrivalRadius`: a room
2.5 m (you are inside it), a door 1.2 m (you stand in front of it), stairs/elevator 1.5 m, otherwise 1 m. NOTE: a
`MapNode` is a single point, so a room has no true extent; the radius is a stand-in for its bounding box. Giving rooms
real extents would be a change to the shared model.
5. **Turn cues carry an angle.** "Turn right" is as easily 15 degrees as 90 to someone who cannot see. Now
"Turn right 45 degrees.", rounded to 5 degrees - finer is false precision given the heading estimate and a person
turning on the spot.
6. **One direction at a time.** `directionCooldownSeconds` (1.5 s) between direction cues. A held-back cue is NOT
dropped: `lastKey` is left alone so it is announced on a later tick. Obstacles and lost tracking are never delayed.
**Status:** accepted; 136 tests pass. All six are **UNVERIFIED ON DEVICE** - every threshold here (3 m lookahead,
45/22 degrees, 3 ticks, 1.0 m revisit, 1.5 s cooldown, the arrival radii) is a considered guess that wants a real walk.

## D-028 — A* result is simplified before it is walked; sighted debug overlay (2026-10-17)
Report from Rice Hall: "it keeps making me do weird turns - I had to walk straight then turn left, but it made me walk
straight, turn right, turn around, then walk straight. Isn't the pathfinding supposed to be doing it normally?"
**A* was never wrong.** It returns the optimal path over the graph, but the graph is a trail of where the VOLUNTEER
walked, including every detour and every time they stepped back to tag something. Optimal-on-that-graph still contains
their U-turns. The missing piece was a step between "shortest path on the trail" and "a path a person would walk".
`RouteSimplifier` (run by `Router.route` by default; pass `simplify: false` for the raw path) does two passes:
detour removal (if the path returns within 1.2 m of somewhere it has already been, the round trip in between is
dropped) and thinning (a node goes if leaving it out moves the path less than 0.6 m, so a straight run of breadcrumbs
becomes one leg and the user hears one instruction instead of six).
**Safety:** both passes stay inside the walked path - thinning never moves the route more than the tolerance, well
under a corridor's width, and detour removal only collapses a return to a place the volunteer stood. We never cut a
corner we have no evidence is walkable. Nodes that MEAN something are never removed: anything tagged, anything
labelled, and both endpoints of a hazard edge (passed in by `Router`). An earlier version of this change thinned a
stairs node away and the hazard warning vanished with it - caught by an existing test, and now covered directly.
Consequence for drawing: `PlanView` can no longer show the route by highlighting map edges, because consecutive route
nodes often have no direct edge after simplification. It draws the route as its own polyline.
**Debug overlay:** `NavDebugView` (Settings > "Show debug overlay while guiding", default OFF) shows the camera the
session is tracking with, the floor plan with the computed route and the user's position/heading, and the raw status.
It is for the sighted escort, never the blind user, and it reads `NavigationController` directly through
`GuidanceService.debugController` because `GuidanceSnapshot` deliberately carries no geometry.
**Status:** accepted; 145 tests pass. UNVERIFIED ON DEVICE; 1.2 m and 0.6 m are guesses that want a real walk.

## D-029 — Rooms have a floor AREA, derived from the mesh's wall faces (2026-10-17)   [CONTRACT CHANGE]
Report: "it's one cohesive mesh rather than actual wall and object boundaries... it doesn't really detect whether I'm
in a room, it tries to get me to the exact spot I labelled something." The team called this critical.
The information was already being captured - D-020 made per-face classification on-by-default precisely so it would not
be lost - but nothing read it. ARKit hands us one continuous reconstruction with no notion of rooms.
`RoomExtractor` (WaypointCore, pure, tested) builds an occupancy grid on the floor plane from WALL and DOOR faces,
flood-fills from where the volunteer stood, and fits a gravity-aligned rectangle to what it filled. If the fill escapes
to the edge of the search area the space is not enclosed - a corridor, an open-plan floor - and it returns **nil**
rather than invent a room. Refusing to answer matters more than guessing: a wrong room boundary tells a blind user they
have arrived when they are still in the corridor.
`MeshSampler.wallPoints` reads `ARMeshAnchor.geometry.classification` (first use of it in the app), keeping faces
classified wall or door between knee and head height, where a wall is reliably a wall.
**CONTRACT CHANGE:** `MapNode.extent: RoomExtent?` and `BuildingMap.schemaVersion` 1 -> 2. The field is optional, so
schema-1 maps decode unchanged and simply have no extents; `schemaVersion` is declarative (nothing validates it on
load), so nothing rejects an older map. A test decodes a hand-written schema-1 map to prove it.
Arrival now means CONTAINMENT when an extent exists: you have arrived when you are inside the room, anywhere in it,
with a 0.5 m margin so a doorway counts. Without an extent it falls back to `ArrivalRadius` (D-027).
Honest limits: a rectangle, not a polygon (an L-shaped room is covered by its bounding rectangle, and
`areaSquareMeters` records the real enclosed area so the difference is visible); an OPEN door leaks the fill into the
corridor, bounded by the search radius and usually caught by the escape test; and this finds the room you are standing
in, it is not a floor-plan reconstruction of the building. Object boundaries (tables, chairs) are still not segmented -
only walls and doors are read.
**Status:** accepted; 155 tests pass. **UNVERIFIED ON DEVICE** - no real mesh has been through `wallPoints` yet, which
is the part most likely to need tuning (height band, face stride, grid resolution).

## D-030 — Progress is measured ALONG the route; turns are announced from the route's geometry (2026-10-17)
From a Rice Hall walk: "it tells me to turn around, after a few steps it tells me to turn around again, on and on",
and separately "when I go to the room myself it doesn't realise I'm inside - but on one test it did".
**One bug caused both.** `RouteFollower.targetIndex` only advanced when the user came within 1 m of each route
waypoint. Route simplification (D-028) spaced waypoints further apart, so walking a corridor 1.5 m to one side never
"reached" one: the follower kept aiming at a point BEHIND the user -> "turn around" -> they comply, come within 1 m,
it advances, the next target is behind them again. The same stuck index meant arrival was never evaluated (it is only
checked when the current target IS the destination), so standing in the room did nothing - unless the walk happened to
touch every waypoint, which is why it worked once.
Fixes: (1) progress is now the nearest SEGMENT of the route polyline, searched in a small window around the current
index so a route that passes near itself cannot teleport progress, never moving backwards, and ignored entirely when
more than 8 m off route; (2) being inside the destination's `RoomExtent` means arrived, whatever the index thinks.
**Turn cues then had to move too.** With a 3 m steering lookahead the user eases into a corner, so the live bearing
never swings far enough to trip `HeadingCue` and a real turn went unannounced (the end-to-end walk test caught it).
Turns now come from the ROUTE's geometry: `Maneuver.angleRadians` carries the corner's real angle, the planner
announces it at `cornerDistanceMeters` (1.2 m, matching the countdown's existing "too close to warn" cut-off), and the
heading cue stays silent about a turn while a real corner is within 4 m, so one corner produces one cue. The heading
cue's job is now only staying on course. Resulting sequence on the sample route: "in 9 m / 5 m / 2 m, turn right",
then "Turn right 90 degrees." at the corner, then arrival.
Also: the debug overlay draws the route over the CAMERA in AR (markers on the floor, a ribbon between them) as well as
on the plan, and the scan review screen lists each room's measured boundary so a bad extraction is visible on review
rather than during a walk.
**Status:** accepted; 160 tests pass. UNVERIFIED ON DEVICE.

## D-031 — Route from where you STAND, and re-route when you are not on it (2026-10-17)
From a Rice Hall walk around the central core: "it makes me go the long way even though there is clearly a shorter way;
it only corrects it when getting close enough to the path after walking down."
Two causes, both in how the route was chosen rather than in A*:
1. **The start node.** `makeFollower` routed from `graph.nearestNode(to:)` - the single closest breadcrumb. On a loop
corridor the closest node can sit on the WRONG branch: a metre away, but facing the long way round. `Router.bestRoute`
now tries the 8 nearest nodes and keeps the one with the smallest total of "walk to that node" + "route from it", so
the branch that is genuinely shorter from where the user is standing wins.
2. **Nothing ever re-routed.** The follower was built once per session and kept whatever it first decided, so walking a
different (often shorter) way than the volunteer scanned left the app insisting on its original path forever. The
controller now measures the distance from the route polyline each tick and, after 1.5 s consistently more than 5 m off,
rebuilds the route from the current position and says "Recalculating." The thresholds are deliberately slack: normal
corridor drift and a single bad pose sample must not trigger it.
Also added a map-health warning, `unclosedLoop`: the scan passes back through a place it has already been without the
two visits being joined, which is exactly the condition that makes A* take the long way round. It counts REVISITS
rather than cycles, because a straight corridor has no cycles either and that is perfectly fine - flagging it would be
noise. Shown on the review screen so the problem is visible when the map is made, not during a walk.
**Status:** accepted; 167 tests pass. UNVERIFIED ON DEVICE. Thresholds to tune: 8 start candidates, 5 m off-route,
1.5 s dwell, and MapHealth's 1.5 m / 10-node revisit test.

## D-032 — Guidance speech QUEUES; only safety interrupts; nothing nags at a standing user (2026-10-17)
Three reports from a Rice Hall walk.
1. **"It cuts itself off a bunch."** Every cue was `.high`, and `.high` interrupted whatever was being said. A walking
user generates several cues in a row, so each one chopped the previous one mid-word. `SpeechPriority` now has three
levels: **critical** (obstacle at STOP range, lost position) interrupts and clears the queue; **high** (turns, arrival,
doors) is QUEUED and spoken in turn - `AVSpeechSynthesizer` queues natively, with a 0.25 s `postUtteranceDelay` so two
lines do not run together; **normal** is ambient and still dropped while anything is speaking.
2. **"It spams 'stop, there is a door ahead'."** Two causes. The stop warning repeats every 3 s, and the door
explanation was re-issued on every level change. Now: the "you will need to open it" line is said ONCE per door and
re-armed only when the way is clear again (so the next door is explained), and a door we were routed through never
enters the repeating stop path at all.
3. **Repeating at someone who has already stopped.** The repeat now requires the user to still be MOVING. Movement is
measured from the ARKit camera pose (>= 0.15 m/s over 0.6 s), not CoreMotion: `CMPedometer`/`CMMotionActivity` would
need `NSMotionUsageDescription`, and they describe the PHONE, while the pose describes the user's position in the map,
which is what we actually care about. `isMoving` is optional - nil means "cannot tell" and keeps the old behaviour.
Also: arrival is now "inside the room **OR** within the arrival radius". Extent-only meant that a room measured too
small - a corner of a large room, say - made arrival LATER than before the extents existed, which is the "it makes me
walk all the way to where I labelled it" report. The two rules together can only ever make arrival earlier.
NOT done (explicitly deferred by the user): predicting that opening a door will complete the route.
**Status:** accepted; 182 tests pass. UNVERIFIED ON DEVICE. Tune on a phone: 0.15 m/s and the 0.6 s window,
`postUtteranceDelay` 0.25 s.

## D-033 — Slow work moves off the main thread; loading is shown, not hidden (2026-10-17)
Report: "when hitting start record, or navigate, it spends a while frozen while loading."
It was not a missing spinner - it was the main thread being blocked. `Relocalizer.start` read the `.arworldmap` off
disk and ran `NSKeyedUnarchiver.unarchivedObject` **on the main thread**, and those files are tens of megabytes;
`CaptureController.start` did the same when EXTENDING a map, plus `MapBundle.validate()`. Loading the marker images
out of the asset catalog was on there too. A spinner over a blocked main thread does not even animate, so the fix had
to be the threading first.
Both now read and decode on a background queue and hand the result back to the main thread, where only `session.run`
remains (ARKit requires it). Each exposes `isPreparing`, so the UI can say what is happening:
`NavigationController` mirrors it and sets the status to "Opening the saved scan...", the classic navigator shows a
row with a spinner, and `GuidanceSnapshot.derive` maps that status to the **localizing** phase - without that it fell
through to `.idle` and the new interface looked stuck rather than busy.
Cancellation matters here: a load that finishes AFTER the user backed out must not grab the camera, so both check
`isPreparing` before running the session, and `stop()` clears it.
**Status:** accepted; 185 tests pass. **UNVERIFIED ON DEVICE** - the freeze was reported on a phone and the fix has
not been timed on one. If "Start recording" still pauses on a NEW (non-extend) scan, the remaining cost is ARKit
starting the camera, which we cannot move.
