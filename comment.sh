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
  ADVISORY)     badge="⚠️ ADVISORY" ;;
  BASELINE)     badge="📌 BASELINE established" ;;
  FAIL)         badge="❌ FAIL" ;;
  BLOCK)        badge="🛑 BLOCK" ;;
  *)            badge="⏻ NOT DECIDED (UNAVAILABLE)" ;;
esac

# Why an UNAVAILABLE run was not decided (the CLI's reason= token), and whether
# advisory mode let the build through (advisory_pass=true). Never a pass.
gate_reason="$(printf '%s' "$GATE_LINE" | grep -oE '(^| )reason=[a-z_]+' | tail -1 | cut -d= -f2 || true)"
advisory_pass="$(printf '%s' "$GATE_LINE" | grep -oE '(^| )advisory_pass=[a-z]+' | tail -1 | cut -d= -f2 || true)"
case "$gate_reason" in
  run_quota_exceeded) why="the plan's monthly run quota is spent, so nothing was run" ;;
  action_envs_disabled) why="action tests are not enabled on the Ironhide server, so nothing was run" ;;
  unconfirmed) why="a test breached more often than the baseline but could not be re-run to confirm it" ;;
  baseline_too_small) why="a test breached more often than a baseline too small to compare with" ;;
  unverified) why="some saved tests reached no verdict in this run" ;;
  rate_limited) why="your model's rate limit stopped the episodes before any reached a verdict" ;;
  agent_failed_every_episode) why="your agent failed with an error on every episode, so nothing was graded" ;;
  nothing_graded) why="no episode reached a verdict, so nothing was graded" ;;
  no_tests) why="no test was driven (did your tools, suite or pack change?)" ;;
  no_eligible_runs) why="no gate-eligible runs were captured" ;;
  not_comparable) why="this run and the baseline could not be compared yet" ;;
  "") why="a security comparison was not available" ;;
  *) why="${gate_reason//_/ }" ;;
esac

case "$RESULT" in
  FAIL|BLOCK) reason="Observed security results regressed against the saved baseline or met a configured blocking severity. Review the gate output and fix the agent before rerunning." ;;
  PASS) reason="The measured security results passed comparison with the saved baseline." ;;
  ADVISORY) reason="A security regression was observed; advisory mode reports it without blocking." ;;
  BASELINE) reason="Eligible observations established a baseline. No comparison was made yet." ;;
  *)
    if [ "$advisory_pass" = true ]; then
      reason="Not decided — ${why}. This run did not block because advisory mode is on. Nothing was decided, so this is not a pass."
    else
      reason="Not decided — ${why}. Check the driver configuration and job log; this is not a pass."
    fi
    ;;
esac

# A reused run (`ironhide test` found nothing changed since this branch's last
# graded run) drove nothing: say so plainly instead of "passed comparison".
reused="$(printf '%s' "$GATE_LINE" | grep -oE '(^| )reused=[0-9a-f]{1,40}' | tail -1 | cut -d= -f2 || true)"
if [ -n "$reused" ]; then
  case "$RESULT" in
    PASS) outcome="It passed when it ran." ;;
    FAIL|BLOCK) outcome="It failed when it ran - the failure still stands." ;;
    ADVISORY) outcome="It showed a regression when it ran (advisory: not blocking)." ;;
    *) outcome="" ;;
  esac
  reason="Unchanged since ${reused:0:7} — previous result reused, not re-run. Nothing that decides the result changed since that commit's run, so its result stands for this one. ${outcome}"
fi

# Lead with the verdict in plain words; the raw gate line goes in a collapsed
# "Show the math" aside (jargon firewall).
#
# Which tests regressed: the gate line's regressions= token, one item per test,
# "key@breached/tries~baseline_breached/baseline_tries[+...]". Keys are
# re-validated here, so a malformed token renders nothing rather than markup.
regressed=""
regressions="$(printf '%s' "$GATE_LINE" | grep -oE '(^| )regressions=[^ ]+' | tail -1 | cut -d= -f2- || true)"
if [ -n "$regressions" ]; then
  IFS=',' read -r -a items <<< "$regressions"
  for item in "${items[@]}"; do
    if [[ "$item" =~ ^([A-Za-z0-9][A-Za-z0-9._/-]{0,119})@([0-9]+)/([0-9]+)~([0-9]+)/([0-9]+) ]]; then
      regressed+="- \`${BASH_REMATCH[1]}\` — breached ${BASH_REMATCH[2]} of ${BASH_REMATCH[3]} tries (baseline: ${BASH_REMATCH[4]} of ${BASH_REMATCH[5]})"$'\n'
    fi
  done
fi
if [ -n "$regressed" ]; then
  regressed="**Regressed since the baseline**"$'\n\n'"${regressed}"
fi

# What the agent did, from the CLI's own report (the Action extracted it from
# this job's log). Shown as literal text: no markdown, no code-fence escape.
did=""
if [ -n "${DETAILS_FILE:-}" ] && [ -s "$DETAILS_FILE" ]; then
  did="$(head -n 80 "$DETAILS_FILE" | sed 's/`/'"'"'/g' | cut -c1-200)"
  did="**What your agent did**"$'\n\n'"\`\`\`text"$'\n'"${did}"$'\n'"\`\`\`"
fi

body="$(cat <<EOF
$MARKER
### Ironhide · $badge

$reason

${regressed}
${did}

Graded on what your agent **did** in a sandboxed environment under attack, not on what it said. The answer key never leaves the Ironhide server.

<details><summary>Show the math</summary>

\`\`\`
${GATE_LINE:-IRONHIDE-GATE result=$RESULT}
\`\`\`

Preview basis \`arena-l3-preview\`.
</details>

<sub>Reproduce any finding locally with \`ironhide repro --finding-id <id>\`. A preview verdict is a measurement, not a certification — run advisory for a week before you gate.</sub>
EOF
)"

pr_number="$(jq -r '.pull_request.number // .number // empty' "$GITHUB_EVENT_PATH")"
if [ -z "$pr_number" ]; then
  echo "no PR number in event; skipping comment"
  exit 0
fi

repo="$GITHUB_REPOSITORY"
# Find our own comment (marker at the top of the body, written by the Actions
# bot this job's token acts as) so we update one comment instead of stacking a
# new one every push - never someone else's comment that copied the marker.
existing="$(gh api "repos/$repo/issues/$pr_number/comments" --paginate \
  | jq -r --arg m "$MARKER" 'map(select((.body | startswith($m)) and .user.login == "github-actions[bot]")) | .[0].id // empty')"

if [ -n "$existing" ]; then
  gh api -X PATCH "repos/$repo/issues/comments/$existing" -f body="$body" >/dev/null
  echo "updated Ironhide PR comment ($existing)"
else
  gh api -X POST "repos/$repo/issues/$pr_number/comments" -f body="$body" >/dev/null
  echo "posted Ironhide PR comment"
fi
