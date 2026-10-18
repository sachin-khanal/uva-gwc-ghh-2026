#!/bin/sh
# File:    scripts/phone-maps.sh
# Owner:   D (build system)
# Purpose: Back up / restore the maps stored INSIDE the app on a connected iPhone (Documents/Maps: map.json, ARWorldMap scan files, 3D
#          models). Reinstalling the app (make install, make uitest, Xcode) can reset its data, and a scan's position data cannot be
#          recreated except by walking the building again. `make install` and `make uitest` run `backup` first.
# Usage:   DEVICE=<id> sh scripts/phone-maps.sh backup          copies to ~/Library/Caches/Waypoint/map-backups/<timestamp>/
#          DEVICE=<id> sh scripts/phone-maps.sh restore [DIR]   copies DIR (default: newest backup that has a scan file) back to the phone
#          sh scripts/phone-maps.sh list                        shows the backups on this Mac
set -eu
BUNDLE="${BUNDLE_ID:-io.github.sachin-khanal.waypoint.sachin}"
ROOT="$HOME/Library/Caches/Waypoint/map-backups"
cmd="${1:-}"
need_device() { [ -n "${DEVICE:-}" ] || { echo "Set DEVICE=<id>; list with 'make devices'"; exit 1; }; }

case "$cmd" in
  backup)
    need_device
    dest="$ROOT/$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$dest"
    # devicectl cannot copy a whole folder in one go: list the files, then copy each one.
    xcrun devicectl device info files --device "$DEVICE" --domain-type appDataContainer --domain-identifier "$BUNDLE" --subdirectory Documents 2>/dev/null \
      | awk '/^Maps\// && $0 !~ /Directory/ {print $1}' > "$dest/.files" || true
    count=0
    while read -r f; do
      [ -n "$f" ] || continue
      mkdir -p "$dest/$(dirname "$f")"
      if xcrun devicectl device copy from --device "$DEVICE" --domain-type appDataContainer --domain-identifier "$BUNDLE" \
           --source "Documents/$f" --destination "$dest/$f" >/dev/null 2>&1; then count=$((count + 1)); fi
    done < "$dest/.files"
    rm -f "$dest/.files"
    if [ "$count" -eq 0 ]; then rmdir "$dest" 2>/dev/null || true; echo "backup: no maps on the phone (or the app is not installed)"; else echo "backup: $count file(s) -> $dest"; fi
    # Keep only the newest 5 backups (each can be 100 MB+); older ones are removed.
    ls -1dt "$ROOT"/*/ 2>/dev/null | tail -n +6 | while read -r old; do rm -rf "$old"; done
    ;;
  restore)
    need_device
    src="${2:-}"
    if [ -z "$src" ]; then
      for d in $(ls -1d "$ROOT"/*/ 2>/dev/null | sort -r); do
        if ls "$d"Maps/*/worldmap-*.arworldmap >/dev/null 2>&1; then src="$d"; break; fi
      done
    fi
    [ -n "$src" ] && [ -d "$src/Maps" ] || { echo "restore: no backup with a scan file found in $ROOT"; exit 1; }
    echo "restoring from $src"
    (cd "$src" && find Maps -type f) | while read -r f; do
      xcrun devicectl device copy to --device "$DEVICE" --domain-type appDataContainer --domain-identifier "$BUNDLE" \
        --source "$src/$f" --destination "Documents/$f" >/dev/null 2>&1 && echo "  $f" || echo "  FAILED $f"
    done
    echo "restore done. Relaunch the app (maps are read when it starts)."
    ;;
  list)
    ls -1d "$ROOT"/*/ 2>/dev/null | while read -r d; do
      n=$(find "$d" -type f | wc -l | tr -d ' '); w=$(ls "$d"Maps/*/worldmap-*.arworldmap 2>/dev/null | wc -l | tr -d ' ')
      echo "$d  files=$n  scans=$w"
    done
    ;;
  *) echo "usage: DEVICE=<id> sh scripts/phone-maps.sh backup | restore [DIR] | list"; exit 2;;
esac
