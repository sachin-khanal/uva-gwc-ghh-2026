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
