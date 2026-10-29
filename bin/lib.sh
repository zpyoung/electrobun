# Shared paths and the fork lock for the quirky tooling scripts. Sourced, never run.
set -euo pipefail

TOOLS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMMON="$(cd "$TOOLS" && cd "$(git rev-parse --git-common-dir)" && pwd)"
WORK="$(dirname "$TOOLS")/electrobun-unified"
LOCK="$COMMON/quirky.lock"
STATE="$COMMON/quirky-rebuild.state"
PATCHES="$TOOLS/patches.txt"

die() { echo "error: $*" >&2; exit 1; }

base_tag() {
  sed -n 's/^# base \(v[0-9][0-9.]*\)$/\1/p' "$PATCHES" | head -1
}

# prints "branch<TAB>test command" for each listed patch
patch_lines() {
  awk '!/^[[:space:]]*(#|$)/ { b = $1; $1 = ""; sub(/^[[:space:]]+/, ""); print b "\t" $0 }' "$PATCHES"
}

state_get() { [ -f "$STATE" ] && sed -n "s/^$1=//p" "$STATE" || true; }

state_set() {
  touch "$STATE"
  grep -v "^$1=" "$STATE" > "$STATE.tmp" || true
  echo "$1=$2" >> "$STATE.tmp"
  mv "$STATE.tmp" "$STATE"
}

# the lock is a directory; a paused rebuild keeps it until --continue or --abort
lock_acquire() {
  local owner="$1" waited=0
  until mkdir "$LOCK" 2>/dev/null; do
    if [ ! -f "$STATE" ] && [ -f "$LOCK/pid" ] && ! kill -0 "$(cat "$LOCK/pid")" 2>/dev/null; then
      echo "removing stale lock held by $(cat "$LOCK/owner" 2>/dev/null)" >&2
      rm -rf "$LOCK"
      continue
    fi
    if [ $((waited % 60)) -eq 0 ]; then
      echo "waiting for the fork lock, held by $(cat "$LOCK/owner" 2>/dev/null || echo unknown)" >&2
    fi
    sleep 5
    waited=$((waited + 5))
  done
  echo "$owner" > "$LOCK/owner"
  echo $$ > "$LOCK/pid"
}

lock_release() { rm -rf "$LOCK"; }
