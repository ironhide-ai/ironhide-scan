#!/usr/bin/env bash
# Upsert a single Ironhide verdict note on the GitLab MR. Reads RESULT and
# GATE_LINE from the environment (set by the CI job). Needs curl + jq and a
# GITLAB_TOKEN with `api` scope — CI_JOB_TOKEN cannot post notes. The gate is
# enforced by the job's exit code regardless; this only adds the comment.
set -euo pipefail

MARKER="<!-- ironhide-scan -->"
RESULT="${RESULT:-UNAVAILABLE}"
GATE_LINE="${GATE_LINE:-}"

: "${CI_API_V4_URL:?CI_API_V4_URL not set (run inside GitLab CI)}"
: "${CI_PROJECT_ID:?CI_PROJECT_ID not set}"
iid="${CI_MERGE_REQUEST_IID:-}"
if [ -z "$iid" ]; then echo "not a merge-request pipeline; skipping note"; exit 0; fi

tok="${GITLAB_TOKEN:-${IRONHIDE_GITLAB_TOKEN:-}}"
if [ -z "$tok" ]; then
  echo "no GITLAB_TOKEN (api scope) set — skipping MR note (the gate still ran)"
  exit 0
fi

case "$RESULT" in
  PASS)         badge="✅ PASS" ;;
  WARN)         badge="⚠️ WARN" ;;
  INCONCLUSIVE) badge="◽ INCONCLUSIVE — unverified, not a pass" ;;
  BASELINE)     badge="📌 BASELINE established" ;;
  FAIL)         badge="❌ FAIL" ;;
  BLOCK)        badge="🛑 BLOCK" ;;
  *)            badge="⏻ UNAVAILABLE" ;;
esac

fence='```'
body="$(printf '%s\n### Ironhide · %s\n\nObserved-state verdict — graded on what your agent **did** in a sandboxed arena under attack, not what it said. Preview basis `arena-l3-preview`.\n\n%s\n%s\n%s\n\nReproduce a finding locally: `ironhide repro --finding-id <id>`.' \
  "$MARKER" "$badge" "$fence" "${GATE_LINE:-IRONHIDE-GATE result=$RESULT}" "$fence")"

base="$CI_API_V4_URL/projects/$CI_PROJECT_ID/merge_requests/$iid/notes"
existing="$(curl -fsS --header "PRIVATE-TOKEN: $tok" "$base?per_page=100" \
  | jq -r --arg m "$MARKER" 'map(select(.body | startswith($m))) | .[0].id // empty')"

if [ -n "$existing" ]; then
  curl -fsS --request PUT --header "PRIVATE-TOKEN: $tok" \
    --data-urlencode "body=$body" "$base/$existing" >/dev/null
  echo "updated Ironhide MR note ($existing)"
else
  curl -fsS --request POST --header "PRIVATE-TOKEN: $tok" \
    --data-urlencode "body=$body" "$base" >/dev/null
  echo "posted Ironhide MR note"
fi
