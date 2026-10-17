#!/usr/bin/env bash
# File:    scripts/team-id.sh
# Purpose: Print the Apple DEVELOPMENT TEAM ID (10 chars) from your Apple Development certificate(s).
# Why:     The "(XXXXXXXXXX)" shown by `security find-identity` is a certificate/person id and is NOT the team id.
#          The team id is the certificate subject's OU field, which is what DEVELOPMENT_TEAM needs.
# Usage:   make team-id     then copy the printed line into Config/Local.xcconfig
set -u
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# Split the keychain's PEM output into one file per certificate.
security find-certificate -a -c "Apple Development" -p 2>/dev/null | awk -v dir="$tmp" '
  /-----BEGIN CERTIFICATE-----/ { n++; file = sprintf("%s/cert%03d.pem", dir, n) }
  { if (file) print > file }'

for pem in "$tmp"/cert*.pem; do
  [ -e "$pem" ] || continue
  subject=$(openssl x509 -in "$pem" -noout -subject -nameopt multiline 2>/dev/null)
  team=$(printf '%s\n' "$subject" | awk -F'= ' '/organizationalUnitName/{print $2; exit}')
  name=$(printf '%s\n' "$subject" | awk -F'= ' '/commonName/{print $2; exit}')
  if [ -n "$team" ]; then
    echo "DEVELOPMENT_TEAM = $team    # $name"
  fi
done | sort -u

# Friendly hint when nothing was printed above because no certificate exists yet.
if ! security find-certificate -a -c "Apple Development" >/dev/null 2>&1; then
  echo "No 'Apple Development' certificate found. Create one: Xcode > Settings > Accounts > Manage Certificates > + (see docs/SETUP.md)." >&2
  exit 1
fi
