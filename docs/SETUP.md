# Setup — from a fresh Mac to the app running on your iPhone

Goal: after the one-time GUI steps, everything is done from the terminal with `make`.
Uses a **free Apple ID** (no paid developer program). Time: about 15 minutes per Mac.

## 0. Requirements

- A Mac with **Xcode 16 or newer** (this team's Mac has Xcode 27.1) and Homebrew.
- A **Pro iPhone with LiDAR** (iPhone 12 Pro or newer) on iOS 17+, plus a USB cable.
  The Simulator cannot run ARKit scanning/LiDAR, so a physical phone is mandatory for AR work.
  Non-Pro phones can still run the non-AR parts (UI, routing, sync).
- An Apple ID (any; free).

## 1. Xcode first launch (one time, needs admin password)

```bash
sudo xcodebuild -runFirstLaunch      # installs required system components
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
xcodebuild -version                  # must print a version and NOT an error about plug-ins
```

**Known issue seen on this team's Mac (2026-10-17):** `xcodebuild` failed with
`IDESimulatorFoundation ... CoreSimulator.framework ... no such file`. That means the first-launch
components were not installed yet. `sudo xcodebuild -runFirstLaunch` fixes it. Until it is fixed,
`make typecheck` and `make test` still work, but `make check/build/run` do not.
**Update 2026-10-17:** ~~Until it is fixed, `make check/build/run` do not work.~~ Fixed on Sachin's Mac after running `sudo xcodebuild -runFirstLaunch`; `make check` now reports BUILD SUCCEEDED. Other Macs may still need it (`make doctor` tells you).

## 2. Repo tools

```bash
git clone <repo-url> && cd uva-gwc-ghh-2026     # or use the shared Live Share folder
make setup        # installs xcodegen (Homebrew), creates Config/Local.xcconfig, runs the doctor
make test         # should print "Executed 45 tests, with 0 failures"
make typecheck    # should print "typecheck OK"
```
**Update 2026-10-18 (Claude, audit):** `make test` now prints `Executed 337 tests, with 0 failures` (the block above is fenced and cannot be struck). The Supabase steps in section 5 now go up to migration `0005` (and the optional hardening `0006_abuse_limits.sql`, see docs/SECURITY.md); `python3 tools/supabase_check.py` verifies the project.
**Update 2026-10-17 (Claude):** in the block above, ~~"Executed 45 tests"~~ is now `Executed 85 tests, with 0 failures` (Swift) plus 9 Python tests (`python3 -B -m unittest discover -s tools -p "test_*.py"`).

## 3. Signing with a free Apple ID (one time, GUI)

1. Open **Xcode** → **Settings** → **Accounts** → **+** → add your Apple ID. A "Personal Team"
   appears.
2. ~~Find your **Team ID** (10 characters): run `security find-identity -v -p codesigning`
   after step 3 below, or Xcode → Settings → Accounts → select account → Team.~~
   **Update 2026-10-17 (Claude, found while setting up U1):** that command's `(XXXXXXXXXX)` is NOT the team id (it is a certificate/person id). Run **`make team-id`** after
   Xcode has created your certificate; it prints the real team id (from the certificate's OU field) as a ready-to-paste `DEVELOPMENT_TEAM = ...` line.
   Creating the certificate: Xcode → Settings → Accounts → your Apple ID → Manage Certificates → + → Apple Development, or open the project (`make open`), select the
   Waypoint target → Signing & Capabilities → tick *Automatically manage signing* → choose your Personal Team. 
3. Edit `Config/Local.xcconfig` (created by `make setup`):
   ```
   DEVELOPMENT_TEAM = ABCDE12345        # your Team ID
   WAYPOINT_DEV_SUFFIX = yourname       # lowercase letters/digits; makes the bundle id unique
   ```
4. Plug in the iPhone, unlock it, tap **Trust This Computer**.
5. iPhone: **Settings → Privacy & Security → Developer Mode → On** (phone restarts). 
6. `make gen && make open`, pick your phone as the run destination, press ▶ **once**. This lets
   Xcode register the phone and create the provisioning profile. It will fail the first time with
   "Untrusted Developer" → on the phone: **Settings → General → VPN & Device Management →
   your Apple ID → Trust**. Run again; the app opens.
   (After this you no longer need the Xcode app.)

## 4. Run from the terminal

```bash
make devices                      # copy the phone's "Identifier" (a UUID-like string)
export DEVICE=<identifier>        # or prefix each command: DEVICE=<id> make run
make run                          # build + sign + install + launch; streams the app's console
```

First launch asks for Camera and Local Network permissions — tap **Allow** on both (Local Network
is required for map sharing; if you deny it, sync silently fails; re-enable in iOS Settings → Waypoint).

## 5. Supabase backend (optional until you want the cloud library)

The app works fully offline without this; cloud features just show "Cloud not configured".
A teammate does this ONCE for the whole team (one shared project), then shares the two public values.

1. https://supabase.com -> New project (free tier). Pick any region, save the DB password somewhere safe.
2. **Authentication -> Providers -> Anonymous Sign-Ins -> enable.** (The app signs in anonymously; there is no signup screen.)
3. **SQL Editor** -> paste all of `supabase/migrations/0001_init.sql` -> Run. It is safe to re-run.
   **Update 2026-10-17 (Claude):** ~~0001 alone is enough~~ the app now talks to `canonical_buildings` and `rpc/extend_building`, which only exist after you ALSO run `0002_canonical_maps.sql` and then `0003_extension_connections.sql` (in that order). Optional checks: `supabase/tests/canonical_maps.sql` and `supabase/tests/extension_connections.sql` (expect PASS notices; fixtures roll back).
   **Update 2026-10-18 (Claude):** then also run `0005_map_extras_constraint.sql`, and RE-RUN the current `0004` if an older copy was run (it is now an exact-path rule).
   **Update 2026-10-17 (Claude):** also run `supabase/migrations/0004_storage_read_policy.sql` (after 0003). A live two-user test found scan files unreadable by other users without it. Then `python3 tools/supabase_check.py` must print PASS for every line (read-only; `--write` runs a full publish/share/extend round trip and leaves one test building).
4. **Project Settings -> API:** copy the *Project URL* and the **anon public** key.
   **Never** copy the `service_role` key into the app, the repo, a chat or a screenshot.
5. Each developer adds to their own `Config/Local.xcconfig` (git-ignored):
   ```
   SUPABASE_URL = https:/$()/YOUR-PROJECT-REF.supabase.co
   SUPABASE_ANON_KEY = YOUR-ANON-PUBLIC-KEY
   ```
   The odd `https:/$()/` is deliberate: in an xcconfig file `//` starts a comment.
6. `make run` again. Share maps -> "Cloud library" should say **Cloud ready**.

Reality check (verify numbers in your dashboard): the free tier allows about 500 MB database, 1 GB file storage,
50 MB per file, and **pauses the project after about a week without use** -> open the dashboard and click
Restore before the demo. If Cloud shows "denied access (401/403)": Anonymous Sign-Ins is off or the SQL
was not run. The anon key is public by design; the SQL's Row Level Security rules are what protect data.

## Headless / UI testing from the terminal (2026-10-17)

`DEVICE=<id> make selftest-sim`, `make selftest-scan` and `make uitest` test the app on your phone without tapping (see docs/TESTING.md). Requirements: phone unlocked and awake
(Settings > Display & Brightness > Auto-Lock > Never while testing), volume up. `make uitest` also uses Settings > Developer > Enable UI Automation. The first `make uitest` installs a second tiny app, the
test runner, under your Apple ID (free accounts allow ~10 new app ids per week; the runner uses one).

## Free-account limits to remember

- The app **expires after 7 days** (re-run `make run` to renew). Fine for a 24h hackathon.
- Max **3 sideloaded apps per phone** and **10 new bundle ids per Apple ID per week**.
- No TestFlight, iCloud, push notifications. We use none of them.
- Wireless debugging: Xcode → Window → Devices and Simulators → check "Connect via network" once
  while cabled; afterwards `make devices` lists it as connected over the network.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `xcodebuild` says a required plug-in failed (CoreSimulator) | `sudo xcodebuild -runFirstLaunch`, then retry |
| `codesign ... resource fork, Finder information... not allowed` | Build output must be outside iCloud folders (`~/Desktop`, `~/Documents`). The Makefile already does this; do not pass your own `-derivedDataPath` inside the repo |
| ~~`No profiles for 'edu.virginia.waypoint.<x>' were found`~~ **Update 2026-10-17:** `No profiles for 'io.github.sachin-khanal.waypoint.<x>' were found` | `DEVELOPMENT_TEAM` empty/wrong in `Config/Local.xcconfig`, or you have not added your Apple ID in Xcode |
| `Failed to register bundle identifier` | Someone else already used that suffix with a free account; pick a more unique `WAYPOINT_DEV_SUFFIX` |
| "Untrusted Developer" on phone | Settings → General → VPN & Device Management → Trust |
| Developer Mode option missing | Plug phone into the Mac with Xcode once; the option appears after |
| `devicectl` shows the phone as unavailable | Unlock it, re-plug, accept the trust prompt |
| AR/LiDAR features do nothing | You are on a non-Pro phone or the Simulator |
| Cloud says "not configured" | `SUPABASE_URL` / `SUPABASE_ANON_KEY` missing in `Config/Local.xcconfig`, or you did not rebuild (`make run`) |
| Sync never finds peers | Both phones need Local Network permission and Wi-Fi/Bluetooth on; use the AirDrop export fallback |

**Update 2026-10-17 (Claude):** **Every developer, once per clone:** `make hooks` (done by `make setup`; on Windows without make run `sh scripts/docs-sync.sh install` in Git Bash). It installs the pre-commit hook that requires a `docs/WORKLOG.md` entry with every code commit (AGENTS.md rule 12). Verify with `make doctor`.
