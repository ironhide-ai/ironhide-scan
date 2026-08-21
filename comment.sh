#!/usr/bin/env bash
# Upsert a single Ironhide verdict comment on the PR. Requires GH_TOKEN with
# pull-requests: write, plus gh + jq (preinstalled on GitHub runners).
set -euo pipefail

MARKER="<!-- ironhide-scan -->"
RESULT="${RESULT:-UNAVAILABLE}"
GATE_LINE="${GATE_LINE:-}"

case "$RESULT" in
  PASS)         badge="✅ PASS" ;;
  WARN)         badge="⚠️ WARN" ;;
  INCONCLUSIVE) badge="◽ INCONCLUSIVE — unverified, not a pass" ;;
  BASELINE)     badge="📌 BASELINE established" ;;
  FAIL)         badge="❌ FAIL" ;;
  BLOCK)        badge="🛑 BLOCK" ;;
  *)            badge="⏻ UNAVAILABLE" ;;
esac

body="$(cat <<EOF
$MARKER
### Ironhide · $badge

Observed-state verdict — graded on what your agent **did** in a sandboxed arena under attack, not on what it said. Preview basis \`arena-l3-preview\`.

\`\`\`
${GATE_LINE:-IRONHIDE-GATE result=$RESULT}
\`\`\`

<sub>Reproduce any finding locally with \`ironhide repro --finding-id <id>\`. A preview verdict is a measurement, not a certification — run advisory for a week before you gate.</sub>
EOF
)"

pr_number="$(jq -r '.pull_request.number // .number // empty' "$GITHUB_EVENT_PATH")"
if [ -z "$pr_number" ]; then
  echo "no PR number in event; skipping comment"
  exit 0
fi

repo="$GITHUB_REPOSITORY"
# Find our own comment (marker at the top of the body) so we update one comment
# instead of stacking a new one every push.
existing="$(gh api "repos/$repo/issues/$pr_number/comments" --paginate \
  | jq -r --arg m "$MARKER" 'map(select(.body | startswith($m))) | .[0].id // empty')"

if [ -n "$existing" ]; then
  gh api -X PATCH "repos/$repo/issues/comments/$existing" -f body="$body" >/dev/null
  echo "updated Ironhide PR comment ($existing)"
else
  gh api -X POST "repos/$repo/issues/$pr_number/comments" -f body="$body" >/dev/null
  echo "posted Ironhide PR comment"
fi
