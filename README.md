# uva-gwc-ghh-2026

Girls Who Code @ UVA 
Girls Hoo Hack 2026 (Won Best Overall)

# Waypoint — indoor navigation for blind users

A sighted volunteer walks a building once with an iPhone Pro (ARKit + LiDAR); the scan becomes a
shared map with doors, stairs and room labels. A blind user later navigates it by **spatial audio**
(the next turn is heard from that direction) and **haptics**, with on-device obstacle detection and
sign reading. ~~Maps sync phone-to-phone with no server.~~ **Update 2026-10-17:** maps sync through a Supabase cloud library (anonymous sign-in), with phone-to-phone sharing and AirDrop as the offline fallback. Demo: blindfolded judge walks to a room in
Rice Hall. (Original brief: [objective.txt](objective.txt).)

## Quick start

```bash
make setup        # installs xcodegen, creates Config/Local.xcconfig (then edit it)
make test         # 45 unit tests of the pure logic, no phone needed
make typecheck    # type-check the iOS app against the iOS SDK, no phone needed
DEVICE=<id> make run   # build + install + launch on your iPhone  (see docs/SETUP.md first)
```

`make help` lists everything. The first-time Mac/phone/signing setup is in
[docs/SETUP.md](docs/SETUP.md). **No need to open the Xcode app after that.**

## Read these (in this order)

| Doc | For |
|---|---|
| [AGENTS.md](AGENTS.md) | Rules for LLM agents and a checklist for humans. **Read first.** |
| [docs/MODULES.md](docs/MODULES.md) | Who owns what, status of each module, interfaces, backlog |
| [docs/WORKLOG.md](docs/WORKLOG.md) | Running log of every change (newest first). Add an entry when you finish a block of work |
| [docs/WORKFLOW.md](docs/WORKFLOW.md) | Working together: Live Share and/or git |
| [docs/ROADMAP.md](docs/ROADMAP.md) | What to work on now: parallel workstreams, milestones, cut lines (Supabase + live scanner) |
| [docs/TESTING.md](docs/TESTING.md) | What is automatically proven, and the on-device test plan |
| [docs/SETUP.md](docs/SETUP.md) | Fresh Mac to running app, free Apple ID signing, troubleshooting |
| [docs/DECISIONS.md](docs/DECISIONS.md) | Why things are the way they are |
| [docs/SECURITY.md](docs/SECURITY.md) | **Update 2026-10-18:** what data the app stores and sends, what protects it, open security/privacy findings |
| [docs/MAP_FORMAT.md](docs/MAP_FORMAT.md) | **Update 2026-10-18:** the map file format, one spec per version, how to change it |
| [Architecture.md](Architecture.md) | The full design and 24-hour plan |

## Repo map

```
Package/WaypointCore/   pure logic (model, storage, routing, feedback rules, vision math) + tests
Waypoint/               iOS app: App, UI, Capture, Relocalization, Navigation, Guidance, Vision, Sync
Samples/                ~~hand-written sample map (also bundled in the app)~~ **Update 2026-10-18 (Claude):** test fixtures only (unit tests, web viewer tests); NOT bundled in the app any more
supabase/migrations/    **Update 2026-10-17:** database + storage schema with Row Level Security (run in the Supabase SQL editor)
project.yml  Config/    XcodeGen spec + per-developer signing config (Local.xcconfig is git-ignored)
Makefile  scripts/      every build/test/run command
docs/  AGENTS.md        documentation
```

## Status

First scaffold is in place and the pure logic is tested (~~45 tests passing~~ 337, see the 2026-10-18 update below). Everything that touches
ARKit, LiDAR, audio, haptics or Multipeer compiles but has **not yet run on a device**. See
[docs/WORKLOG.md](docs/WORKLOG.md) for the exact state.

**Update 2026-10-17 (build block 1):** added a live LiDAR scan view with a bounding box, a Simulate mode for testing guidance without a scan, and a Supabase client + SQL schema. Tests: 45 passing. Still untested on a phone and against a real Supabase project. Next steps per person: [docs/ROADMAP.md](docs/ROADMAP.md); device test plan: [docs/TESTING.md](docs/TESTING.md).

**Update 2026-10-17 (Claude):** test counts above (~~45~~) are now 85 Swift tests in `make test`, 9 Python tests for `tools/validate_map.py`, and 7 on-device UI tests. Cloud now uses one shared map per building (migrations 0002 and 0003, see `supabase/CANONICAL_MAPS.md`) and a volunteer can extend an existing building's map. All AR/audio/haptic/cross-phone behavior remains UNVERIFIED ON DEVICE where the WORKLOG says so.

**Update 2026-10-18 (Claude, audit):** current numbers: `make test` runs **337** Swift tests (the code block above still says 45: it is a fenced block and cannot be struck), `python3 -m unittest discover -s tools` 16 Python tests, `make uitest` 11 UI tests on a phone, `make selftest-e2e` 25 on-device checks (35 when the opt-in `-e2eCloudWrite YES` two-user cloud test is added). The repo map above is missing: `web/` (U3's standalone building viewer), `tools/` (map validator, `supabase_check.py`), `docs/map-format/` (one fixture per map format version), `Waypoint/Model3D/` (3D model viewer) and `Waypoint/Services/` + `Waypoint/UI/Scanner|Navigator|DesignSystem/` (the new interface, now the DEFAULT). `make selftest-*` only LAUNCH the installed build: run `make build install` first (details in docs/WORKFLOW.md).
