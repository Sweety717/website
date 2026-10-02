#!/usr/bin/env bash
set -euo pipefail

# Turns a fetcher's SYNC-DEGRADED marker (see SYNC_KEY in scripts/fetch/*.java)
# into a tracking issue, but only once a key has been degraded CONTINUOUSLY
# for longer than THRESHOLD_HOURS. A single bad run is noise nobody should be
# paged for -- every fetcher already keeps its committed file and exits 0 for
# exactly that reason. The gap this closes is the opposite one: that same
# "never fail the build" design has no way to say "this has been true for two
# and a half weeks", which is exactly how fetch/Jugs.java went stale from
# 2026-09-15 with every run reporting green.
#
# Usage: sync-health.sh <log-file> <state-file> <key> [<key> ...]
# - <log-file>   combined stdout+stderr of this run's fetch steps
# - <state-file> small JSON file this script owns: {key: {firstDegradedAt, issue}}
#                committed by the caller alongside the data files
#
# Always exits 0 -- a GitHub API hiccup HERE must not fail the sync that is
# trying to report on a GitHub API hiccup elsewhere.

THRESHOLD_HOURS=48

log_file="$1"
state_file="$2"
shift 2

[ -s "$state_file" ] || echo '{}' > "$state_file"

now_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
now_epoch="$(date -u +%s)"

update_state() {
  jq "$@" "$state_file" > "$state_file.tmp" && mv "$state_file.tmp" "$state_file"
}

for key in "$@"; do
  reason="$(grep -m1 "^SYNC-DEGRADED ${key}:" "$log_file" | sed "s/^SYNC-DEGRADED ${key}: //" || true)"
  issue="$(jq -r --arg k "$key" '.[$k].issue // empty' "$state_file")"

  if [ -n "$reason" ]; then
    first="$(jq -r --arg k "$key" '.[$k].firstDegradedAt // empty' "$state_file")"
    if [ -z "$first" ]; then
      first="$now_iso"
      update_state --arg k "$key" --arg t "$first" '.[$k] = {firstDegradedAt: $t}'
      echo "sync-health: $key degraded (first seen this run)"
    fi

    # GNU date (the ubuntu-latest runner this actually runs on) first, BSD
    # date (macOS, for anyone testing this locally) as the fallback.
    first_epoch="$(date -u -d "$first" +%s 2>/dev/null \
      || date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$first" +%s)"
    elapsed_hours=$(( (now_epoch - first_epoch) / 3600 ))

    if [ -z "$issue" ] && [ "$elapsed_hours" -ge "$THRESHOLD_HOURS" ]; then
      title="Data sync: $key has been degraded for ${THRESHOLD_HOURS}h+"
      body="Degraded continuously since $first (UTC) -- at least ${elapsed_hours}h now.

Latest reason reported by the fetcher:

> $reason

This runs with the deliberate design in AGENTS.md: a fetcher keeps its last
good data file and exits 0 rather than failing the build over someone else's
API, so a transient outage costs nothing. This issue exists because a
PERSISTENT failure in that same design is otherwise invisible -- nothing short
of reading the workflow log would have shown it.

Check the upstream source named above. This issue closes itself automatically
once a run comes back healthy."
      new_issue="$(gh issue create --title "$title" --body "$body" 2>&1 | grep -oE '[0-9]+$' || true)"
      if [ -n "$new_issue" ]; then
        update_state --arg k "$key" --argjson n "$new_issue" '.[$k].issue = $n'
        echo "sync-health: opened #$new_issue for $key (degraded ${elapsed_hours}h)"
      else
        echo "sync-health: could not open a tracking issue for $key -- will retry next run"
      fi
    fi
  else
    if [ -n "$issue" ]; then
      gh issue comment "$issue" --body "Recovered as of $now_iso (UTC) -- closing." >/dev/null 2>&1 || true
      gh issue close "$issue" >/dev/null 2>&1 || true
      echo "sync-health: closed #$issue for $key (recovered)"
    fi
    update_state --arg k "$key" 'del(.[$k])'
  fi
done
