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

## 2. Repo tools

```bash
git clone <repo-url> && cd uva-gwc-ghh-2026     # or use the shared Live Share folder
make setup        # installs xcodegen (Homebrew), creates Config/Local.xcconfig, runs the doctor
make test         # should print "Executed 27 tests, with 0 failures"
make typecheck    # should print "typecheck OK"
```

## 3. Signing with a free Apple ID (one time, GUI)

1. Open **Xcode** → **Settings** → **Accounts** → **+** → add your Apple ID. A "Personal Team"
   appears.
2. Find your **Team ID** (10 characters): run `security find-identity -v -p codesigning`
   after step 3 below, or Xcode → Settings → Accounts → select account → Team. 
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
| `No profiles for 'edu.virginia.waypoint.<x>' were found` | `DEVELOPMENT_TEAM` empty/wrong in `Config/Local.xcconfig`, or you have not added your Apple ID in Xcode |
| `Failed to register bundle identifier` | Someone else already used that suffix with a free account; pick a more unique `WAYPOINT_DEV_SUFFIX` |
| "Untrusted Developer" on phone | Settings → General → VPN & Device Management → Trust |
| Developer Mode option missing | Plug phone into the Mac with Xcode once; the option appears after |
| `devicectl` shows the phone as unavailable | Unlock it, re-plug, accept the trust prompt |
| AR/LiDAR features do nothing | You are on a non-Pro phone or the Simulator |
| Sync never finds peers | Both phones need Local Network permission and Wi-Fi/Bluetooth on; use the AirDrop export fallback |
