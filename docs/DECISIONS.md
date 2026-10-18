# Decisions log

**Update 2026-10-17 (Codex, user-directed CONTRACT CHANGE):** personal U3 uses
schema **3** for room extents and separately stored OBJ meshes, retaining main's
serialized MapSchema migration framework (1/2 remain readable). This resolves
navigation-overhaul's different static "schema 2" meaning. OBJ v1 is untextured,
in map-frame meters with baked anchor transforms, SHA-256 and bounds; no third-
party dependency. Mesh assets are immutable; missing extents may be enriched,
while stale graph uploads preserve existing rich fields via migration 0004.
Schema-3 deployment requires coordinated reader/server updates; see MAP_FORMAT.
This records U3 implementation intent, not a main merge or device verification.

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
