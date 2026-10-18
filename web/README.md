# Waypoint building explorer (U3.7)

**Update 2026-10-17 (Codex, schema 3):** viewer now projects XYZ in 3D, with drag
orbit, keyboard arrows while canvas is focused, zoom and Fit. It draws room
footprints (walls only if a measured height exists) and actual untextured OBJ
meshes from schema-3 bundles or canonical cloud manifests. Bytes, SHA-256 and
bounds are verified before geometry is drawn. No mesh reference => graph and
available room footprints only. The sample footprints are synthetic, not a scan.
Current suites: 43 browser logic/geometry checks and 16 UI checks PASS. See
`docs/MAP_FORMAT.md`. Live cloud/native capture still need verification.

Read-only static HTML/JavaScript viewer for shared building maps. No packages,
framework, external fonts, or installation. ~~Sample mode needs no Supabase key.~~ **Update 2026-10-18 (Claude):** the viewer starts EMPTY (no sample building any more); connect your library or open a local map file.

## Run

From the repository root in the VS Code terminal:

```powershell
python -B web/serve.py
```

Open **http://127.0.0.1:8000/web/**. Leave the terminal running; Ctrl+C stops it.
Use `--port 8001` if 8000 is occupied. On a Mac use `python3`.
Do not double-click index.html: JavaScript modules and fixtures need HTTP.
The loopback server exposes only static web assets and the two sample JSON files.

## Use

- Select a building, starting point and destination. Click a labeled plan marker
  or destination button to see its route. Zoom buttons and Fit map adjust the plan.
  The selectors provide keyboard alternatives to canvas interaction.
- Stairs are amber. The default preference applies the native router's 1000 m
  stairs penalty; stairs remain available as fallback and show an explicit warning.
  Displayed distance excludes the penalty. Other route hazards also show a warning.
- Local JSON maps or `.waypointmap` bundles up to 5 MB can be opened without upload.
  Large bundles should be opened as their smaller `map.json`. Graph structure is
  validated before rendering; binary scan files are not used by this viewer.
- ~~The plan projects X/Z coordinates; multiple levels may overlap and are flagged.~~
  **Update 2026-10-17 (Codex):** the 3D view uses X/Y/Z and preserves floor heights.
  This is a preview, without live positioning or on-site navigation guidance.

## Shared library

Click **Connect library**, use the pre-filled project URL and your **anon public
key**, then connect. Never use service_role/secret keys. The viewer signs in
anonymously and reads `canonical_buildings`. Refresh after a phone publishes a
map. Empty libraries keep the sample available; invalid maps are skipped/reported.

~~Requires anonymous sign-ins and migrations 0001/0002 (0003 aligns extension rules).~~
**Update 2026-10-17 (Codex):** apply migrations 0001 through **0004**, in order,
for schema-3 cloud publication, enrichment and shared mesh reads. The new migration
has not been applied by the agent. Binary OBJ reads use the same anonymous JWT.
A map stored only on a phone must be published before it appears. Connection
details and tokens remain in memory, not browser storage; reloading clears them.
The anonymous identity is reused/refreshed during the tab's lifetime. Repeated
reload/reconnect can hit auth rate limits. Tests use mock responses; live-cloud
verification still needs the team's anon public key and a published map.

## Tests

With the server running, open:

- http://127.0.0.1:8000/web/tests.html — ~~33~~ **Update 2026-10-17 (Codex):** 43 routing, validation, geometry and cloud mock checks.
- http://127.0.0.1:8000/web/ui-tests.html — ~~13~~ **Update 2026-10-17 (Codex):** 16 real DOM interaction checks, including
  file imports, canvas clicks, cloud mock, empty/unreachable routes and 390px layout.

Optional Node 20+ runner: `node web/test-web.mjs` (no npm install needed).
Node is not needed to use the viewer or run browser checks.

Both browser and native `RouteVectorTests.swift` read the SAME expected paths in
`Samples/route-vectors.json`. Run `make test` on a Mac to verify native parity;
the new native test has NOT run here. Float arithmetic uses Math.fround and can
differ at rounding boundaries. Equal-cost ties are unspecified and avoided in
the shared fixtures. No native router/model schema changes were made.

This is repository-local development: no hosted deployment or Git push.


**Update 2026-10-17 (Codex):** Captured OBJ scans now render as solid, shaded, depth-tested surfaces using built-in WebGL, with every triangle retained. Use **Cutaway height** to look inside and **Route overlay** to show navigation over the scan (the overlay stays readable through surfaces). Surface view opens automatically when verified geometry loads. This supersedes the earlier sampled/translucent display description; stored meshes are unchanged. Missing mesh data still shows the navigation graph. Actual scan geometry supplies walls/floors/objects; the viewer does not synthesize them from navigation points. OBJ has no photographic textures or true colors. Browser regression checks now total 62 (46 logic/GPU + 16 UI), passing in headless Edge with software WebGL; real LiDAR fidelity/performance remains unverified.

**Update 2026-10-17 (Codex, main integration):** the browser's synthetic schema-3 sample lives in web/fixtures/rice-hall-sample.json. The native Samples/rice-hall-sample.json stays at main's schema 2. Shared route vectors are provided for browser tests; their Swift consumer remains on the U3 development checkout, pending native integration. The viewer accepts schema 1/2/3 independently of native capture support. Local bundles can contain meshFiles (OBJ bytes), subject to the 5 MB import limit; ARWorldMap binaries are not rendered. The loopback server also serves JSON fixtures under web/.

**Update 2026-10-17 (Codex, deployment):** the earlier statement that rich-map SQL was not applied is stale: connected Supabase has rich-map functions plus mesh policy/validator fixes and corrected worldmap reads. These backend/native changes are separate from this web-only commit. Do not infer that other projects have been migrated. Browser cloud checks use mocks; real downloads and real scan performance remain unverified. This commit is being prepared for the user's requested push to main, superseding the earlier repository-local-only note.

**Update 2026-10-18 (Codex):** web viewer adds Walk through/Walk to destination, eye-level perspective and double-click/double-tap travel along stored graph connections. Unlabeled points/background edges hidden by default, recoverable with Show unlabeled points; routing data unchanged. Floor 4 currently has no attached mesh: walkthrough shows mapped positions/routes, not real walls. Real geometry appears only when a verified OBJ is available. Browser checks 49 logic/GPU + 19 UI PASS; Python 22 PASS. Physical device/real scan verification pending.

**Update 2026-10-18 (Codex, architectural preview):** maps without an OBJ now generate an explicitly estimated solid building (floor, corridor walls, room shapes and door frames) from the complete saved graph and named places. This supersedes the route-only display described above. Default room sizes/corridor width/wall heights are assumptions; measured extents take precedence. Real OBJ remains preferred. Raw points/labels are never removed from storage. Floor 4 local snapshot is served only by opt-in --preview-map TEMPFILE and ?floor4=1; private snapshot is not committed. Browser checks 51 logic/GPU + 19 UI PASS, Python 22 PASS; physical accuracy unverified.

**Update 2026-10-18 (Codex, route interaction):** selecting a destination reveals its route; in walk mode it retargets travel immediately. Start route follows the selection and reports arrival. Expand map enlarges the canvas while retaining route controls. Browser checks now 51 logic/GPU + 22 UI PASS, including a complete synthetic trip to arrival; actual building geometry/physical routing remains unverified.

**Update 2026-10-18 (Codex, visual cleanup):** estimated walls now use simplified interior/exterior contours, consistent thickness and caps; finer floor cells and wall-foot strips reduce jagged edges/cracks. Neutral floors, smaller markers and staggered full-name labels improve close viewing. All named features and routing source data retained.

**Update 2026-10-18 (Codex, clarified close-up):** layout retained; walking uses a wider perspective, gentler bounded zoom, and arrival just inside the doorway. Inferred rooms have full 2.8 m walls and ceilings during walking, with cutaway overview. Selected path sits on floor; unrelated graph/leader lines removed and wall-hidden labels suppressed only from the current view. All saved names remain in the complete list. 53 logic/GPU + 22 UI checks PASS. Dimensions remain estimates.

**Update 2026-10-18 (Codex, floor tour):** Walk through automatically starts in the corridor near Room 412 when available, follows rendered mapped hallways around reachable named places and returns there. Exit/Fit cancels; selecting a room retargets. Original route start restored after tour. Actual Floor 4 snapshot checked: 229 connected steps, no skipped anchors, closed return. Browser checks 54 logic/GPU + 22 UI PASS.

**Update 2026-10-18 (Codex, named places only):** Floor 4 preview hides corridor geometry/markers and raw corridor choices; duplicate exact 412 is suppressed when Room 412 exists. Room 412 and all other named locations retained. Underlying graph/data unchanged for routing. Supersedes the visible hallway preview above. Actual snapshot has 34 visible named entries; 55 logic/GPU + 22 UI checks PASS.

**Update 2026-10-18 (Codex, clarification):** corridor shapes remain visible in Floor 4. Only start/end choices omit raw corridor entries; Room 412 remains and duplicate exact 412 is suppressed. This supersedes the previous named-place-only geometry description.

**Update 2026-10-18 (Codex, entrances):** inferred door frames are smaller (0.82 x 2.05 m), anchored to rendered room/corridor boundaries, with lintel wall panels. Detached frames at raw tag positions are no longer drawn. Names/routing data preserved; door dimensions remain display estimates. Browser checks 56 logic/GPU + 22 UI PASS.

**Update 2026-10-18 (Codex, specified tour):** Floor 4 Walk through now starts at stairs near Room 401, follows the main corridor around, pauses by elevator and bathroom, and finishes at Room 420-428. This supersedes the earlier closed tour from Room 412. Includes modeled loop connectors, steady eye height and smoothed heading. Actual snapshot: 82 connected steps, zero skipped requested anchors. Browser checks 57 logic/GPU + 22 UI PASS.


**Update 2026-10-18 (Codex, completed viewer handoff):** Cross-referenced `origin/U3` eaed57e. Schema 1–4 maps are accepted, including validated stair metadata. The U3 walkthrough, architectural reconstruction, compact attached doors and routing remain intact. Default startup is empty; connect a shared library or open a real map. No private snapshot endpoint or runtime fixture is shipped. Buildings with mesh references are listed first and marked “3D scan”; this indicates a reference, with verification performed when opened.

Large scans now show download progress, time out only after a 20-second stall, verify exact byte size/SHA-256/bounds, and use typed arrays through OBJ parsing and surface upload. Up to three verified meshes stay in tab memory; reopening reuses them. Cache identity includes manifest size and bounds as well as the content hash. No scan data is written to browser storage. Failed geometry leaves the route graph available. Room walls shown without a captured mesh are explicitly estimated.

Current checks: `node web/test-web.mjs` → 73/73 PASS, 2 browser-only SKIP. Serve with `python3 -B web/serve.py --port 8041`; `/web/tests.html` → 74/74 PASS and `/web/ui-tests.html` → 24/24 PASS in fresh headless Chrome with software WebGL. Native branch checks: 349 tests PASS; typecheck PASS. Live cloud and real scan visual fidelity were not verified in this session. This completion is local to `feature/web-viewer-integration`; no hosted deployment or push was performed.


**Update 2026-10-18 (Codex, live E2E):** The viewer is now verified against all four real shared buildings and the published 26.2 MB OBJ (676,599 triangles), with actual surface-pixel checks and browser screenshots. `tools/test_live_viewer.mjs` passes 23 live checks; all 30,355 ordered node routes validate. Disabled-WebGL feedback remains visible next to the map after import. Cross-user download, session refresh, unauthenticated denial, offline recovery and real-map arrival pass. Two backend failures remain: schema-4 uploads are rejected by the deployed validator, and an update can attach an unpublished mesh reference through `extend_building`. See `docs/VIEWER_QA_2026-10-18.md`; these are failing SQL regressions, not successful deployment checks. No physical phone walk or Safari verification was performed.
