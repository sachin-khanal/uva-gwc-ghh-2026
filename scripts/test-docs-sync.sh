#!/bin/sh
# File:    scripts/test-docs-sync.sh
# Purpose: Prove scripts/docs-sync.sh and the pre-commit hook behave, in a THROWAWAY git repo (never touches this one).
#          Run: `make test-hooks` or `sh scripts/test-docs-sync.sh`. Exit 0 = all cases pass.
set -u
SRC=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/docs-sync-test.XXXXXX") || exit 2
trap 'rm -rf "$T"' EXIT
pass=0; failn=0
ok()  { pass=$((pass+1)); printf '  PASS %s\n' "$1"; }
bad() { failn=$((failn+1)); printf '  FAIL %s\n' "$1"; }

cd "$T" || exit 2
git init -q . && git config user.email t@example.com && git config user.name Tester && git config commit.gpgsign false
mkdir -p scripts docs Waypoint
cp -R "$SRC/scripts/githooks" scripts/githooks && cp "$SRC/scripts/docs-sync.sh" scripts/docs-sync.sh
printf '# Work log\n\nintro\n' > docs/WORKLOG.md
printf '# Modules\n' > docs/MODULES.md
printf '// File: A.swift\nlet a = 1\n' > Waypoint/A.swift
sh scripts/docs-sync.sh install --quiet
[ "$(git config core.hooksPath)" = "scripts/githooks" ] && ok "install sets core.hooksPath" || bad "install sets core.hooksPath"
sh scripts/docs-sync.sh status && ok "status reports installed" || bad "status reports installed"
git add -A && git commit -q -m base -n

entry() { # entry <heading-suffix> [extra lines...]
  printf '# Work log\n\n## 2026-10-17 10:00 — T — %s   [tags: BUILD]\nVerified: ran %s\nNOT verified: UNVERIFIED ON DEVICE (%s)\n\nintro\n' "$1" "$1" "$1" > docs/WORKLOG.md
}
reset() { git reset -q --hard HEAD; git clean -fdq; }

# 1. code without WORKLOG -> blocked
echo 'let a = 2' >> Waypoint/A.swift; git add -A
out=$(git commit -m c1 2>&1); rc=$?
[ $rc -ne 0 ] && echo "$out" | grep -q "BLOCKED" && ok "code without WORKLOG is blocked" || bad "code without WORKLOG is blocked (rc=$rc)"
reset

# 2. docs-only change -> allowed
echo 'more' >> docs/MODULES.md; git add -A
git commit -q -m c2 >/dev/null 2>&1 && ok "docs-only commit is allowed" || bad "docs-only commit is allowed"

# 3. stub leaves placeholders -> blocked
echo 'let a = 3' >> Waypoint/A.swift
sh scripts/docs-sync.sh stub >/dev/null 2>&1; git add -A
head -4 docs/WORKLOG.md | grep -q '<FILL: one-line summary>' && ok "stub prepends a skeleton at the top" || bad "stub prepends a skeleton at the top"
grep -q '`Waypoint/A.swift`' docs/WORKLOG.md && ok "stub lists the changed file" || bad "stub lists the changed file"
out=$(git commit -m c3 2>&1); rc=$?
[ $rc -ne 0 ] && echo "$out" | grep -q "placeholders" && ok "unfilled stub is blocked" || bad "unfilled stub is blocked (rc=$rc)"
reset

# 4. code + real entry -> allowed
echo 'let a = 4' >> Waypoint/A.swift; entry "real change"; git add -A
git commit -q -m c4 >/dev/null 2>&1 && ok "code + filled WORKLOG entry is allowed" || bad "code + filled WORKLOG entry is allowed"

# 5. WORKLOG touched but no new entry heading -> blocked
echo 'let a = 5' >> Waypoint/A.swift; echo 'stray line' >> docs/WORKLOG.md; git add -A
out=$(git commit -m c5 2>&1); rc=$?
[ $rc -ne 0 ] && echo "$out" | grep -q "no NEW" && ok "WORKLOG edit without a new entry is blocked" || bad "WORKLOG edit without a new entry is blocked (rc=$rc)"
reset

# 6. entry missing NOT verified -> blocked
echo 'let a = 6' >> Waypoint/A.swift
printf '# Work log\n\n## 2026-10-17 11:00 — T — x   [tags: BUILD]\nVerified: ok\n\nintro\n' > docs/WORKLOG.md; git add -A
out=$(git commit -m c6 2>&1); rc=$?
[ $rc -ne 0 ] && echo "$out" | grep -q "NOT verified" && ok "entry without NOT verified is blocked" || bad "entry without NOT verified is blocked (rc=$rc)"
reset

# 7. escape hatch
echo 'let a = 7' >> Waypoint/A.swift; git add -A
WAYPOINT_SKIP_DOCS=1 git commit -q -m c7 >/dev/null 2>&1 && ok "WAYPOINT_SKIP_DOCS=1 skips the local check" || bad "WAYPOINT_SKIP_DOCS=1 skips the local check"

# 8. rule 11 warning (does not block)
printf 'line one\nline two\n' > docs/NOTES.md; git add -A; git commit -q -m n1 >/dev/null 2>&1
printf 'line one\nCHANGED\n' > docs/NOTES.md; git add -A
out=$(git commit -m c8 2>&1); rc=$?
[ $rc -eq 0 ] && echo "$out" | grep -q "Rule 11" && ok "markdown rewrite without strikethrough warns but does not block" || bad "markdown rewrite warning (rc=$rc)"

# 9. new swift file without header warns
printf 'let b = 1\n' > Waypoint/B.swift; entry "new file"; git add -A
out=$(git commit -m c9 2>&1); rc=$?
[ $rc -eq 0 ] && echo "$out" | grep -q "missing the header" && echo "$out" | grep -q "not listed in docs/MODULES.md" && ok "new Swift file warns about header and MODULES.md" || bad "new Swift file warnings (rc=$rc)"

# 10. CI range mode
git checkout -q -b feature
echo 'let a = 10' >> Waypoint/A.swift; git add -A; WAYPOINT_SKIP_DOCS=1 git commit -q -m c10 >/dev/null 2>&1
BASE=$(git rev-parse HEAD~1)
sh scripts/docs-sync.sh check --range "$BASE" >/dev/null 2>&1 && bad "range check blocks a branch without a WORKLOG entry" || ok "range check blocks a branch without a WORKLOG entry"
echo 'let a = 11' >> Waypoint/A.swift; entry "ci"; git add -A; git commit -q -m c11 >/dev/null 2>&1
sh scripts/docs-sync.sh check --range "$BASE" >/dev/null 2>&1 && ok "range check passes once an entry exists" || bad "range check passes once an entry exists"

printf '\n%s passed, %s failed\n' "$pass" "$failn"
[ "$failn" -eq 0 ]
