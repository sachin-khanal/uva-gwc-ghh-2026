# Shared building maps

Apply `migrations/0002_canonical_maps.sql` in Supabase SQL Editor after `0001`.
Use the updated client with this migration; old clients still use contributor rows.
The migration keeps the original tables and data intact. Re-publish existing local
maps to add them to the canonical library. Existing contributor copies are not
automatically combined, because their conflicting scan frames need review.

Each building is identified by its map UUID, not its display name. Publish once;
other users download that building and extend the SAME map UUID. A fresh scan
with a fresh map UUID creates a different building entry even if its name matches.
Each new scan must have a unique safe segment ID and be aligned to the existing
map frame. ~~The capture/relocalization owner still needs to implement the complete
extend-existing-map scanning flow; this change implements the cloud merge path.~~
**Update 2026-10-17 (Codex, requested by U3):** the volunteer screen now supports
selecting an existing local/downloaded building and saved scan segment. It loads
that segment's ARWorldMap, waits for normal tracking, and requires the volunteer
to begin near a mapped corridor/junction. Recording attaches to that point within
2 m in 3D and 0.75 m vertically, keeps the building UUID, and uses a fresh segment
ID. Missing scan files block extension. This flow is implemented but
UNVERIFIED ON DEVICE and pending Mac compile/tests.

**Update 2026-10-17 (Codex):** apply `migrations/0003_extension_connections.sql`
AFTER 0002, then run `tests/extension_connections.sql` and re-run
`tests/canonical_maps.sql`. The new wrapper matches the existing local import
rule: new edges may attach new nodes, but cannot connect two already-known nodes
unless that connection already exists. Existing applied migrations are unchanged.
The wrapper holds the same transaction lock as the merge function. Its internal
merge function cannot be called directly by authenticated/anonymous API roles.
These SQL scripts have not yet been run against the live project.

All signed-in users can list and download canonical maps. Extensions add nodes
and edges without removing earlier contributions. Conflicting edits are rejected.
Server serialization prevents concurrent or stale uploads from losing additions.
The first publisher remains recorded as owner; that does not restrict extension.
Scan contributor IDs are recorded separately so downloads use the correct folder.
Every cloud download requires the existing Import review tap.

Verification: run `tests/canonical_maps.sql` in SQL Editor AFTER migration 0002.
It creates temporary fixtures, checks two-user extension and stale publication,
and rolls everything back. Expected notice: PASS. This script has not been run
in this Windows workspace (no PostgreSQL installed). Mac teammate must also run
`make test` and `make typecheck` before merging. UNVERIFIED ON DEVICE.

**Update 2026-10-17 (Claude):** LIVE TEST RESULT. Against the real project, two different anonymous users could publish, see, download and extend the shared MAP DATA (rows, version counter, stale re-upload safe; publish ~0.5 s, list ~0.1 s), but a second user could NOT download the first user's scan files ("Object not found" for every ARWorldMap): the storage read rule `canonical_worldmaps_read` was not effective on the live project, and 0002's SQL test never covered it (it ran against stubbed storage functions). Fix: run `migrations/0004_storage_read_policy.sql`, then `python3 tools/supabase_check.py`. The client now reports scan files it could not download instead of dropping them silently (`SyncEngine.fetchBundleChecked`, shown in the import review). Test rows named `ZZ CONNECTION TEST ...` cannot be deleted by the app (migration 0002 revokes delete); remove them in the SQL editor with `delete from public.canonical_buildings where name like 'ZZ CONNECTION TEST%';`.

**Update 2026-10-18 (Claude):** after running the corrected `0004_storage_read_policy.sql`, `python3 tools/supabase_check.py` passes everything and the phone round trip passes 33/33 (publish, share, extend, stale upload, 5 timed download cycles, 0 failures, about 140-240 ms each). Only small test scan files (4 KB / 2 KB) have been exercised so far.

**Update 2026-10-18 (Claude):** security review follow-ups, both tested in a local Postgres (not yet applied to the live project):
- `0004_storage_read_policy.sql` now matches the scan file's FULL path exactly (`<contributor>/<building>/<segment>.arworldmap` for a pair in `segment_owners`). The first 0004 (and 0002) were looser: a contributor could host `seg1.anything` or `seg1.arworldmap/x` for everyone. RE-RUN the current file even though an older 0004 is installed (it drops and re-creates the rule). Test: `supabase/tests/storage_read_policy.sql` (1 of 8 hostile/odd names readable).
- NEW `0005_map_extras_constraint.sql`: a CHECK constraint so the database refuses maps with invalid room floor areas (`nodes[].extent`) or malformed `meshAssets`, whichever client sent them (the first publication stores the incoming JSON as is). Run after 0004. Test: `supabase/tests/map_extras_constraint.sql` (15 cases + the constraint itself).

**Update 2026-10-18 (Claude):** `0008_mesh_publish_and_read.sql` is APPLIED on the live project. It adds `publish_mesh_assets` and `remove_mesh_asset` (a signed-in user can list or delist only OBJ files for their own segments, size and SHA-256 checked, quota per contributor and per building), the `canonical_meshes_read` storage rule (an exact path listed in `meshAssets`, the listed owner must be the segment's contributor, the stored size must match) and a trigger that strips `meshAssets` from a building's first publication. It also DROPS `canonical_mesh_read`, a looser rule of the same purpose that was applied to the live project outside this repo. Result on the phone: `make selftest-e2e EXTRA="-e2eCloudWrite YES"` 41 passed, 0 failed. The numbering gap (0006/0007) is because the live project's own history has differently named entries (`mesh_read_policy`, `geometry_validator_alias`, `worldmaps_read_policy`, `storage_read_policy_exact_paths`, `map_extras_constraint`, `mesh_read_policy_qualified_paths`).
