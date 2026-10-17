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
map frame. The capture/relocalization owner still needs to implement the complete
extend-existing-map scanning flow; this change implements the cloud merge path.

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
