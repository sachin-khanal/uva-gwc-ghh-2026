# Decisions log

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
