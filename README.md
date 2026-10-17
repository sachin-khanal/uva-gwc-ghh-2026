# uva-gwc-ghh-2026

Girls Hoo Hack 2026

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
| [Architecture.md](Architecture.md) | The full design and 24-hour plan |

## Repo map

```
Package/WaypointCore/   pure logic (model, storage, routing, feedback rules, vision math) + tests
Waypoint/               iOS app: App, UI, Capture, Relocalization, Navigation, Guidance, Vision, Sync
Samples/                hand-written sample map (also bundled in the app)
supabase/migrations/    **Update 2026-10-17:** database + storage schema with Row Level Security (run in the Supabase SQL editor)
project.yml  Config/    XcodeGen spec + per-developer signing config (Local.xcconfig is git-ignored)
Makefile  scripts/      every build/test/run command
docs/  AGENTS.md        documentation
```

## Status

First scaffold is in place and the pure logic is tested (45 tests passing). Everything that touches
ARKit, LiDAR, audio, haptics or Multipeer compiles but has **not yet run on a device**. See
[docs/WORKLOG.md](docs/WORKLOG.md) for the exact state.

**Update 2026-10-17 (build block 1):** added a live LiDAR scan view with a bounding box, a Simulate mode for testing guidance without a scan, and a Supabase client + SQL schema. Tests: 45 passing. Still untested on a phone and against a real Supabase project. Next steps per person: [docs/ROADMAP.md](docs/ROADMAP.md); device test plan: [docs/TESTING.md](docs/TESTING.md).
