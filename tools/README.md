# U3 development tools

**Update 2026-10-17 (Codex, schema 3):** validator reads formats 1/2/3, rejects
future formats, checks room extents, mesh manifests and optional bundle payload
size/SHA-256. Fixtures are in `docs/map-format/`; `test_rich_maps.py` adds six
test methods (15 total Python tests PASS). No geometry is inferred from old files.

Requires Python 3.10+; no packages to install. From the repository root on Windows:

```powershell
python tools/validate_map.py
python tools/validate_map.py "Samples/*.json"
python tools/validate_map.py path/to/export.waypointmap
python -B -m unittest discover -s tools -p "test_*.py" -v
```

~~The default checks every `Samples/*.json` file.~~ **Update 2026-10-17 (Codex):**
the default checks sample map JSON files, excluding `route-vectors.json` (shared
routing test data, not a BuildingMap). Explicit paths and quoted glob
patterns are supported. Each file prints PASS or FAIL with a reason; exit status
is 0 only when every file passes, otherwise 1 (including unmatched patterns).
On a Mac use `python3` instead of `python` if necessary.

**Update 2026-10-17 (Codex):** in the command block above, replace
~~`python tools/validate_map.py "Samples/*.json"`~~ with
`python tools/validate_map.py "Samples/*-sample.json"` to select maps only.
Explicitly selecting a non-map fixture still rejects it. Browser and Swift
shared-vector tests validate the routing fixture separately.

The validator independently checks the current Swift map decoding fields,
`SegmentID` alphabet, and `MapBundle.validate()` limits, references, unique UUIDs,
finite coordinates, and edge distance tolerance (max of 0.5 m or 25%). Bundles
also require valid base64 world maps with safe keys and at most 50 MB per entry.
Unknown extra fields are allowed, as with Swift Codable. Float calculations
approximate Swift SIMD arithmetic; values at rounding boundaries may differ.
Marker numeric fields must be finite (a deliberate stricter check than the
current bundle validator). No new constraints on positive versions, positive
edge distances, connectivity, or unique edges are invented here.

This is a developer check, not proof that a map matches a real building or that
a route is safe. It does not implement the store's existing-map merge checks.
CI wiring (INF-2) is a separate task; this change does not add a workflow.

## supabase_check.py (added 2026-10-17)
`python3 tools/supabase_check.py` checks the real Supabase project the way the app uses it: keys (refuses a service_role key), anonymous sign-in, the shared map list, the `extend_building` function, and whether a brand-new user can download the scan files of the existing test building. Read-only. `--write` also runs the two-user publish / share / extend / stale-upload round trip and leaves one building named `ZZ CONNECTION TEST ...` (delete it in the SQL editor, see the script header). Reads `Config/Local.xcconfig` or `SUPABASE_URL` / `SUPABASE_ANON_KEY`; never prints keys.


## Live viewer E2E — 2026-10-18 (Codex)

`test_live_viewer.mjs` exercises the real Supabase client and an actual browser. Start `python3 -B web/serve.py --port 8041` first. It reads `SUPABASE_URL` / `SUPABASE_ANON_KEY` from the environment or a `--config` xcconfig file. It rejects secret/service-role keys through `CloudLibrary`. Credentials are never printed or persisted by this runner. Anonymous sign-in creates test identities, but it does not publish, update or delete maps.

Use an **already installed** Playwright module/browser (no project dependency is added):

```sh
node tools/test_live_viewer.mjs --config /absolute/path/Config/Local.xcconfig --playwright /absolute/path/playwright-core/index.mjs --browser "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
```

Omit `--playwright` if `playwright-core` already resolves in your environment; omit `--browser` to use its installed Chromium. `--base` defaults to `http://127.0.0.1:8041/web/`. `--artifacts` defaults to a directory under the OS temporary directory. Screenshots contain real floor plans; keep artifacts outside Git. The runner requires nonempty live maps and at least one published OBJ, checks all ordered node pairs, exact OBJ size/hash/bounds, public access denial, cross-user reads, identity refresh, real browser geometry pixels, route completion/arrival, offline recovery, mobile layout, persistent storage, preview path boundaries, and disabled-WebGL fallback. Browser animation time advances for arrival checks; it does not represent a physical walk.

Current result: 23/23 live checks PASS against four shared maps. See `docs/VIEWER_QA_2026-10-18.md` for the separate database failures. Running the live browser suite successfully does **not** imply those SQL regressions pass.
