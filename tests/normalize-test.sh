#!/usr/bin/env bash
# Runs normalize.jq — the same filter the helper uses — over a fixture and
# checks the grouping the panel depends on. No framework: bash and jq.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

# Fixed clock so "overdue" and "due today" mean the same thing on every run.
NOW=1700000000000
DAY_START=1699920000000
DAY_END=1700006399999

failures=0

run() { # run <statusOrder>
  jq -c --argjson now "$NOW" --argjson dayStart "$DAY_START" --argjson dayEnd "$DAY_END" \
    --arg statusOrder "$1" -f normalize.jq tests/fixtures/payload.json
}

check() { # check <name> <expected> <actual>
  if [[ $2 == "$3" ]]; then
    printf 'ok   %s\n' "$1"
  else
    printf 'FAIL %s\n       expected: %s\n       actual:   %s\n' "$1" "$2" "$3"
    failures=$((failures + 1))
  fi
}

out=$(run "") || { echo "normalize.jq failed to run"; exit 1; }
ordered=$(run "backlog, in progress")

# Sections run from the furthest-along open status down to the least started,
# and a status whose list could not be read still shows up, last.
check "default section order" \
  "review|in progress|backlog|waiting on client" \
  "$(jq -r '[.sections[].status] | join("|")' <<<"$out")"

check "statusOrder overrides, unnamed statuses keep API order behind it" \
  "backlog|in progress|review|waiting on client" \
  "$(jq -r '[.sections[].status] | join("|")' <<<"$ordered")"

check "dated work sorts ahead of undated, soonest first" \
  "Overdue task|Due today task|No due date" \
  "$(jq -r '[.sections[] | select(.status == "in progress") | .tasks[].name] | join("|")' <<<"$out")"

check "counts" "6/1/1" \
  "$(jq -r '"\(.totalOpen)/\(.overdue)/\(.dueToday)"' <<<"$out")"

check "section count matches its rows" "3" \
  "$(jq -r '.sections[] | select(.status == "in progress") | .count' <<<"$out")"

check "newest sprint tag becomes the current sprint" "sprint 13📅" \
  "$(jq -r '.currentSprint' <<<"$out")"

# A list living directly in a space reports a placeholder folder flagged hidden.
check "hidden folder is not rendered as a name" "" \
  "$(jq -r '.sections[].tasks[] | select(.id == "ccc333") | .folderName' <<<"$out")"

check "every task carries what a row needs" "6" \
  "$(jq -r '[.sections[].tasks[] | select((.id | length) > 0 and (.name | length) > 0 and (.url | length) > 0 and (.status | length) > 0)] | length' <<<"$out")"

check "list statuses survive for the status picker" "3" \
  "$(jq -r '.listStatuses["111"] | length' <<<"$out")"

if ((failures > 0)); then
  printf '\n%d check(s) failed\n' "$failures"
  exit 1
fi
printf '\nall checks passed\n'
