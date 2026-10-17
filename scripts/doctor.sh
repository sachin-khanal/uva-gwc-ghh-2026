#!/usr/bin/env bash
# File:    scripts/doctor.sh
# Purpose: Diagnose a developer machine. Prints PASS/WARN/FAIL per check and what to do about it.
#          Exit code 1 only if a FAIL (something that blocks building) was found.
#          Run via `make doctor`. Safe: read-only, changes nothing.
set -u
cd "$(dirname "$0")/.."

fail=0
pass() { printf '  \033[32mPASS\033[0m %s\n' "$1"; }
warn() { printf '  \033[33mWARN\033[0m %s\n' "$1"; }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=1; }

echo "Waypoint doctor"

# 1. Xcode
if xcodebuild -version >/dev/null 2>&1; then
  pass "Xcode: $(xcodebuild -version | head -1)"
else
  bad "xcodebuild not working. Install Xcode, then: sudo xcode-select -s /Applications/Xcode.app && sudo xcodebuild -runFirstLaunch"
fi

# 1b. Xcode first-launch components. Without CoreSimulator, xcodebuild aborts before compiling
#     ("A required plugin failed to load"). `make test` and `make typecheck` still work.
if [ -d /Library/Developer/PrivateFrameworks/CoreSimulator.framework ]; then
  pass "CoreSimulator framework installed (xcodebuild can load its plug-ins)"
else
  warn "CoreSimulator framework missing: 'make check/build/run' will fail. Fix: sudo xcodebuild -runFirstLaunch (docs/SETUP.md step 1)"
fi

# 2. devicectl (needed for install/launch)
if xcrun --find devicectl >/dev/null 2>&1; then pass "devicectl present"; else bad "devicectl missing (needs Xcode 15+)"; fi

# 3. XcodeGen
if command -v xcodegen >/dev/null; then pass "xcodegen $(xcodegen --version | head -1)"; else bad "xcodegen missing: run 'make setup' (brew install xcodegen)"; fi

# 4. Local signing config
prefix=$(sed -n 's/^WAYPOINT_BUNDLE_PREFIX *= *//p' Config/Local.xcconfig Config/Base.xcconfig 2>/dev/null | tail -1 | tr -d ' ')
if [ -f Config/Local.xcconfig ]; then
  team=$(sed -n 's/^DEVELOPMENT_TEAM *= *//p' Config/Local.xcconfig | tr -d ' ')
  suffix=$(sed -n 's/^WAYPOINT_DEV_SUFFIX *= *//p' Config/Local.xcconfig | tr -d ' ')
  if [ -z "$team" ] || [[ "$team" == REPLACE* ]]; then
    warn "Config/Local.xcconfig: DEVELOPMENT_TEAM not set (needed for 'make build/run', not for 'make test/check')"
  else
    pass "DEVELOPMENT_TEAM=$team"
  fi
  if [ -z "$suffix" ] || [[ "$suffix" == replacewith* ]]; then
    warn "Config/Local.xcconfig: WAYPOINT_DEV_SUFFIX not set; bundle id will be $prefix.shared"
  else
    pass "bundle id $prefix.$suffix"
  fi
else
  warn "Config/Local.xcconfig missing: run 'make setup' and edit it"
fi

# 5. Signing identity (free Personal Team shows up after adding your Apple ID in Xcode once)
if security find-identity -v -p codesigning 2>/dev/null | grep -q "Apple Development"; then
  pass "Apple Development signing identity found"
else
  warn "No 'Apple Development' identity. Xcode > Settings > Accounts > add Apple ID, then build once from Xcode (docs/SETUP.md)"
fi

# 6. Repo location gotcha
case "$PWD" in
  "$HOME/Desktop"*|"$HOME/Documents"*) pass "Repo is in an iCloud-synced folder; Makefile already builds into ~/Library/Caches/Waypoint to avoid codesign xattr errors" ;;
esac

# 7. Devices
echo "  Connected devices (need 'connected' + Developer Mode on):"
xcrun devicectl list devices 2>/dev/null | sed 's/^/    /' || warn "could not list devices"

exit $fail
