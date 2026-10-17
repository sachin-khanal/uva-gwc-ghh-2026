#!/bin/sh
# File:    scripts/docs-sync.sh
# Owner:   D / U1 (build system)
# Purpose: Keep docs in step with code on EVERY commit (AGENTS.md rule 12). It does not write prose for you;
#          it makes the commit fail until a real docs/WORKLOG.md entry is part of it, and scaffolds that entry.
# Usage:   sh scripts/docs-sync.sh check [--range BASE]  verify (staged files, or BASE...HEAD for CI). Exit 1 = blocked.
#          sh scripts/docs-sync.sh stub                  prepend a pre-filled WORKLOG entry skeleton (fill the <FILL: ...> parts)
#          sh scripts/docs-sync.sh install [--quiet]     point git at scripts/githooks (core.hooksPath); `make hooks` does this
#          sh scripts/docs-sync.sh status                exit 0 if the hook is installed in this clone
#          sh scripts/docs-sync.sh session               used by the Claude Code SessionStart hook: install + print the reminder
# Design:  POSIX sh, no dependencies, runs in Git Bash on Windows. Markdown is only ever APPENDED to (rule 11): the stub
#          adds a new entry at the top and never edits existing text. Rule-11 violations are WARNINGS (typo fixes are legal).
# Escape:  WAYPOINT_SKIP_DOCS=1 git commit ...   (say why in the WORKLOG afterwards; CI still checks the branch).
set -u
ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "docs-sync: not inside a git repository" >&2; exit 2; }
cd "$ROOT" || exit 2

HOOKS_DIR="scripts/githooks"
WORKLOG="docs/WORKLOG.md"

say()  { printf '%s\n' "$*"; }
warn() { printf 'docs-sync WARN: %s\n' "$*" >&2; }

# Files that count as "code": a commit touching any of them needs a WORKLOG entry (AGENTS.md rule 1).
is_code() {
  case "$1" in
    docs/*|*.md|*.txt|Config/Local.xcconfig) return 1 ;;
    *.swift|*.sql|*.py|*.sh|*.yml|*.yaml|*.xcconfig|*.json|*.plist|Makefile|scripts/githooks/*) return 0 ;;
  esac
  return 1
}

cmd_install() {
  quiet=0; force=0
  for a in "$@"; do case "$a" in --quiet) quiet=1 ;; --force) force=1 ;; esac; done
  cur=$(git config --get core.hooksPath 2>/dev/null || true)
  if [ -n "$cur" ] && [ "$cur" != "$HOOKS_DIR" ] && [ "$force" -eq 0 ]; then
    warn "core.hooksPath is already '$cur'; not overriding. Re-run with: sh scripts/docs-sync.sh install --force"
    return 1
  fi
  git config core.hooksPath "$HOOKS_DIR"
  chmod +x "$HOOKS_DIR"/* scripts/docs-sync.sh 2>/dev/null || true
  [ "$quiet" -eq 1 ] || say "docs-sync: git hooks installed (core.hooksPath=$HOOKS_DIR). Commits that change code now need a $WORKLOG entry."
}

cmd_status() {
  [ "$(git config --get core.hooksPath 2>/dev/null || true)" = "$HOOKS_DIR" ]
}

cmd_session() {
  cmd_install --quiet || true
  say "Waypoint docs rule (AGENTS.md rule 12): a commit that changes code must also add a NEW entry at the top of $WORKLOG"
  say "(files, commands run, Verified / NOT verified, handoff) and update docs/MODULES.md etc. if a module's status changed."
  say "A git pre-commit hook enforces this. Scaffold the entry with: sh scripts/docs-sync.sh stub"
  say "Markdown is never rewritten (rule 11): strike through old text and add '**Update YYYY-MM-DD (who):** ...'."
}

# ---- stub ------------------------------------------------------------------------------------------------------------
cmd_stub() {
  [ -f "$WORKLOG" ] || { echo "docs-sync: $WORKLOG not found" >&2; return 2; }
  first=$(sed -n 1p "$WORKLOG"); second=$(sed -n 2p "$WORKLOG")
  if [ "$first" != "# Work log" ] || [ -n "$second" ]; then
    echo "docs-sync: unexpected $WORKLOG header (want '# Work log' + blank line); add the entry by hand" >&2; return 2
  fi
  who=${WAYPOINT_AGENT:-$(git config user.name 2>/dev/null || echo unknown)}
  branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "?")
  stamp=$(date '+%Y-%m-%d %H:%M')
  created=""; edited=""; deleted=""
  # Porcelain covers staged + unstaged + untracked, so the stub works before or after `git add`.
  list=$(git status --porcelain 2>/dev/null | sed 's/^...//' | grep -v "^$WORKLOG\$" || true)
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    x=$(git status --porcelain -- "$line" 2>/dev/null | cut -c1-2)
    case "$x" in
      "??"|"A "|" A"|"AM") created="$created \`$line\`," ;;
      "D "|" D"|"AD"|"MD") deleted="$deleted \`$line\`," ;;
      *) edited="$edited \`$line\`," ;;
    esac
  done <<EOF
$list
EOF
  tmp=$(mktemp "${TMPDIR:-/tmp}/worklog.XXXXXX") || return 2
  {
    head -n 2 "$WORKLOG"
    cat <<EOF
## $stamp — $who — <FILL: one-line summary>   [tags: <FILL: BUILD | DOCS | BUG | CONTRACT CHANGE>]
Area: <FILL: A | B | C | D | shared>   Branch: $branch
Files created:${created:- none}
Files edited:${edited:- none}  <FILL: say WHAT changed in each, not just the path>
Files deleted:${deleted:- none}
Commands run: <FILL: e.g. make test, make typecheck>
Verified: <FILL: command and result, e.g. \`make test\` -> 85 tests, 0 failures>
NOT verified: <FILL: anything on a phone/AR/audio/haptics/Multipeer = UNVERIFIED ON DEVICE; or "nothing">
Open problems / handoff: <FILL: what the next person must know, or "none">

EOF
    tail -n +3 "$WORKLOG"
  } > "$tmp" && cat "$tmp" > "$WORKLOG"
  rm -f "$tmp"
  say "docs-sync: added a skeleton entry at the top of $WORKLOG. Replace every <FILL: ...>, then: git add $WORKLOG"
  say "Also update docs/MODULES.md (module status), docs/TESTING.md, docs/ROADMAP.md, DECISIONS.md if they changed (strike + Update, rule 11)."
}

# ---- check -----------------------------------------------------------------------------------------------------------
cmd_check() {
  range=""
  if [ "${1:-}" = "--range" ]; then range=${2:-}; [ -n "$range" ] || { echo "docs-sync: --range needs a base ref" >&2; return 2; }; fi

  if [ -z "$range" ]; then
    if [ "${WAYPOINT_SKIP_DOCS:-0}" = "1" ]; then
      warn "WAYPOINT_SKIP_DOCS=1: docs check skipped. Add the WORKLOG entry in the next commit and say why you skipped."; return 0
    fi
    gd=$(git rev-parse --git-dir)
    for m in MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD rebase-merge rebase-apply; do
      [ -e "$gd/$m" ] && return 0   # merges, picks and rebases carry other people's already-checked commits
    done
    D="--cached"; show() { git show ":$1" 2>/dev/null; }
  else
    D="$range...HEAD"; show() { git show "HEAD:$1" 2>/dev/null; }
  fi

  names=$(git diff $D --name-only --diff-filter=ACMRD 2>/dev/null || true)
  [ -n "$names" ] || return 0
  code=""
  while IFS= read -r f; do [ -n "$f" ] && is_code "$f" && code="$code
$f"; done <<EOF
$names
EOF
  code=$(printf '%s' "$code" | sed '/^$/d')

  wl_added=$(git diff $D -U0 -- "$WORKLOG" 2>/dev/null | grep '^+' | grep -v '^+++' || true)
  problems=""

  if [ -n "$code" ]; then
    if ! printf '%s\n' "$names" | grep -qx "$WORKLOG"; then
      problems="$problems
  - $WORKLOG is not part of this change, but code is. AGENTS.md rule 1: log every change."
    else
      printf '%s\n' "$wl_added" | grep -Eq '^\+## 20[0-9]{2}-[0-9]{2}-[0-9]{2}' \
        || problems="$problems
  - $WORKLOG changed, but there is no NEW '## YYYY-MM-DD ...' entry (append the entry at the TOP)."
      printf '%s\n' "$wl_added" | grep -q '<FILL' \
        && problems="$problems
  - $WORKLOG still contains '<FILL: ...>' placeholders. Replace them with real text."
      printf '%s\n' "$wl_added" | grep -q 'Verified' \
        || problems="$problems
  - the new entry has no 'Verified:' line (what you ran and the result)."
      printf '%s\n' "$wl_added" | grep -q 'NOT verified' \
        || problems="$problems
  - the new entry has no 'NOT verified:' line (write UNVERIFIED ON DEVICE for anything not run on a phone)."
    fi
  fi

  # ---- warnings (never block) ----
  if [ -n "$code" ]; then
    if printf '%s\n' "$code" | grep -q 'WaypointCore/Model/'; then
      printf '%s\n' "$wl_added" | grep -q 'CONTRACT CHANGE' \
        || warn "you changed Model/* (the data contract). AGENTS.md rule 3: tag the WORKLOG entry CONTRACT CHANGE, update tests and Samples/."
    fi
    added=$(git diff $D --name-only --diff-filter=A 2>/dev/null | grep '\.swift$' || true)
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      show "$f" | head -8 | grep -q '// File:' || warn "$f: missing the header comment (File/Owner/Purpose/Status), AGENTS.md section 4."
      case "$f" in
        Waypoint/*|Package/*/Sources/*)
          b=$(basename "$f"); grep -q "$b" docs/MODULES.md 2>/dev/null || warn "$b is not listed in docs/MODULES.md; add it to the layout/ownership table." ;;
      esac
    done <<EOF
$added
EOF
  fi
  md=$(printf '%s\n' "$names" | grep '\.md$' || true)
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    # Rule 11 = old text must stay readable. A removed line counts as kept if the added text still contains it, or at
    # least every word of it (appends inside a table cell, ~~strikethrough~~ wrapping); otherwise it was overwritten.
    lost=$(git diff $D -U0 -- "$f" 2>/dev/null | awk '/^\+\+\+|^---/ {next} /^\+/ {all = all substr($0,2) "\n"} /^-/ {r[++m]=substr($0,2)} END {c=0; for (i=1;i<=m;i++) {if (index(all, r[i])) continue; k=1; w=split(r[i], t, /[ |]+/); for (j=1;j<=w;j++) if (length(t[j])>=3 && !index(all, t[j])) {k=0; break} if (!k) c++} print c+0}')
    [ "${lost:-0}" -gt 0 ] \
      && warn "$f: old text of $lost line(s) was not kept. Rule 11: ~~strike through~~ the old text and add '**Update YYYY-MM-DD (who):** ...' (typo fixes are fine)."
  done <<EOF
$md
EOF

  if [ -n "$problems" ]; then
    {
      echo "docs-sync: BLOCKED. This change touches code, so the docs must travel with it (AGENTS.md rule 12):"
      printf '%s\n' "$problems" | sed '/^$/d'
      echo "Code files in this change:"; printf '%s\n' "$code" | sed 's/^/    /'
      echo "Fix: sh scripts/docs-sync.sh stub   (adds a skeleton entry), fill it in, git add $WORKLOG, commit again."
      echo "Also update docs/MODULES.md / TESTING.md / ROADMAP.md if status changed (strike + Update, rule 11)."
      echo "Emergency only: WAYPOINT_SKIP_DOCS=1 git commit ...  (then log why)."
    } >&2
    return 1
  fi
  return 0
}

sub=${1:-check}; [ $# -gt 0 ] && shift
case "$sub" in
  check)   cmd_check "$@" ;;
  stub)    cmd_stub ;;
  install) cmd_install "$@" ;;
  status)  cmd_status ;;
  session) cmd_session ;;
  *) echo "usage: sh scripts/docs-sync.sh check [--range BASE] | stub | install [--quiet|--force] | status | session" >&2; exit 2 ;;
esac
