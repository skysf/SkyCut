#!/bin/bash
# Waits for a pull request in the merge slot (docs/build/build-and-packaging.md "Merge slot").
#   exit 0: it is MERGED (the slot also deleted its branch)
#   exit 1: the slot sent it back (the label merge-slot is gone); prints the slot's last comment, which says why
#   exit 2: it was closed without merging
#   exit 3: still waiting when the time limit ran out; run it again
# Usage: scripts/merge-slot-wait.sh <PR number> [max minutes, default 9] [poll seconds, default 60]
set -uo pipefail
pr="${1:?usage: scripts/merge-slot-wait.sh <PR number> [max minutes] [poll seconds]}"
max_minutes="${2:-9}"
poll="${3:-60}"
deadline=$((SECONDS + max_minutes * 60))
while :; do
  # "<state> <1 when labeled, else 0>"; a failed call (network) just waits for the next poll.
  if state="$(gh pr view "${pr}" --json state,labels \
    --jq '.state + " " + ([.labels[].name | select(. == "merge-slot")] | length | tostring)' 2>/dev/null)"; then
    case "${state}" in
      "MERGED "*) echo "#${pr} is merged"; exit 0 ;;
      "CLOSED "*) echo "#${pr} was closed without merging" >&2; exit 2 ;;
      "OPEN 0")
        echo "#${pr} is not in the merge slot (no label merge-slot). The slot's last comment:" >&2
        gh pr view "${pr}" --json comments \
          --jq '[.comments[] | select(.body | startswith("**Merge slot:**"))] | last | .body // "(none yet)"' >&2
        exit 1 ;;
    esac
  fi
  if [ "${SECONDS}" -ge "${deadline}" ]; then
    echo "#${pr} is still in the merge slot after ${max_minutes} minutes; run this again" >&2
    exit 3
  fi
  sleep "${poll}"
done
