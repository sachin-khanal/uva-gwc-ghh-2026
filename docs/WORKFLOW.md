# Working together: Live Share now, git later (undecided)

The team has not decided between VS Code Live Share and a git-based flow. This doc works for both
and for mixing them (e.g. Live Share while pairing, git to move work between machines).

## Principles (both modes)

1. **One owner per area.** See `docs/MODULES.md`. Cross-area edits are small and logged.
2. **Small, frequent, logged changes.** Every change set ends with a `docs/WORKLOG.md` entry.
3. **Freeze the contract early.** `Model/*` changes are announced as `CONTRACT CHANGE`.
4. **Re-read before you edit.** Files change under you, especially in Live Share.
5. **Green before you hand off:** `make test` and `make typecheck` pass.
6. **Markdown edits keep the old text** (rule added 2026-10-17): ~~strike through~~ the stale text and add the new text labelled
   `**Update YYYY-MM-DD (who):**`. Never delete or overwrite. See AGENTS.md rule 11. Code files are exempt.

## Mode 1 — VS Code Live Share (everyone in one working tree on the host's Mac)

- **The host's Mac is the only place that builds.** Guests edit; the host runs `make …`.
  Guests cannot run Xcode tools against the host's checkout and should not try.
- **Phones:** deploying needs the phone cabled to (or wirelessly paired with) the machine
  that runs `make run`. So whoever owns a phone should host while they test, or hand the
  host role over (see "Switching hosts").
- **Avoid two people typing in the same file.** Stick to your area's files. If you must touch a
  shared file (`project.yml`, `Makefile`, `Model/*`, docs), say so in chat first.
- **Agents in Live Share:** LLM agents run on the host's machine and edit the same tree, so they
  can collide with humans. Tell the agent which area to work in; it must log to the WORKLOG.
- **No git needed**, but commit on the host regularly (every milestone) so history exists.
- **Switching hosts:** the old host commits and pushes (or zips the folder); the new host clones/
  pulls, runs `make setup` (creates their own `Config/Local.xcconfig`), `make gen`, then shares.
  `Waypoint.xcodeproj` is never transferred — it is regenerated.
- Terminal sharing: share the terminal read/write only with people you trust; `make run`
  output (console from the phone) is the main debugging tool.

## Mode 2 — Git (each person has their own clone and phone)

- Remote: the GitHub repo `uva-gwc-ghh-2026`. Branch `main` is always green (`make test`, `make typecheck`).
- **Branch per area:** `a/capture`, `b/guidance`, `c/vision`, `d/sync-ui` (add `/<topic>` for more).
- **Small commits, rebase onto main daily** (`git pull --rebase origin main`). Merge to `main`
  via PR or fast-forward; never force-push `main`.
- **Merge-conflict hotspots** and how we avoid them:
  - `.xcodeproj` → git-ignored, never conflicts. Do not remove it from `.gitignore`.
  - `project.yml`, `Makefile` → shared; keep edits tiny, pull first.
  - `docs/WORKLOG.md` → newest entry goes at the TOP; conflicts are trivial (keep both).
  - `Model/*` → announce first.
- **Commit message format:** `area: what changed` e.g. `vision: add depth confidence mask`.
  Agents add a trailer line `Co-authored-by: <agent>` if the tool does not already.
- Each person's `Config/Local.xcconfig` is local and ignored.

## Mixing modes

Fine. Rule of thumb: git is the source of truth between machines; Live Share is for pairing
within a session. Before leaving a Live Share session, the host commits.

## Handoff checklist (end of a work block)

- [ ] `make test` passes, `make typecheck` passes
- [ ] WORKLOG entry written (files, commands, verified / UNVERIFIED ON DEVICE, open issues)
- [ ] `docs/MODULES.md` status updated if a module moved (TODO → SCAFFOLD → DONE)
- [ ] Anything half-done is marked `TODO(owner):` in the code header, not silently left
- [ ] Committed (git mode) or host notified (Live Share mode)
