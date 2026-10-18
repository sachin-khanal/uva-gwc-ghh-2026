# Branch audit — 2026-10-18 (Codex)

Fetched `origin --prune`. Clean working tree before handoff edits. Counts below are commits relative to current `feature/guidance-overhaul` at `a9f909e`, before these uncommitted edits.

| Remote branch | Current-only | Remote-only |
|---|---:|---:|
| navigation-overhaul | 0 | 0 |
| main / integrate/navigation-overhaul | 10 | 0 |
| U3 | 8 | 36 |
| app-ui-workflows | 71 | 0 |
| chore/audit-2026-10-18 | 10 | 2 |
| feature/share-size-policy | 23 | 0 |
| feature/web-mesh-obj | 10 | 12 |
| map-extension | 8 | 4 |
| stairs-multifloor | 8 | 15 |

Local `main`, `integrate/navigation-overhaul`, audit, share-size and web-mesh branches match their corresponding remote tips. Local `U3` is 95 commits behind `origin/U3`. `chore/supabase-mcp-example` has no upstream and equals main. Local `feature/guidance-overhaul` tracks `origin/navigation-overhaul`, not a same-named remote branch.

Local `feature/web-viewer-integration` is seven commits ahead of remote main and checked out in `/private/tmp/claude-501/wv`; this worktree was left untouched. Its commits include the U3 viewer integration and routing-test adjustment. No same-named remote branch exists.

Claude's latest handoff is voice settings (4035431), preceded by narration proxy (a8b6812) and speech queue fixes (ab215fc). All are in current HEAD. U3 lacks eight commits from this line, including those voice changes. Its 36 additional commits include audit, scan extension, stairs, mesh publication and viewer work; these are separate integration work, with native checks not run in U3's Windows handoff.

Resume performed here: applied the NavigatorView/UI-test portion of e44a288 and corrected the obstacle test for the stationary-user rule. Required checks: 406 core tests pass; iOS app and UI tests typecheck. Revised UI behavior remains UNVERIFIED ON DEVICE.

Integration issue: current guidance has `0009_narration_limits.sql`, while U3 has `0009_rich_map_schema.sql` plus `0010_geometry_validator_alias.sql`. Reconcile numbering against the deployed migration history before combining branches; do not renumber an already applied migration casually. No live migration or remote branch was changed here.
