#!/usr/bin/env bash
# Upsert a single Ironhide verdict comment on the PR. Requires GH_TOKEN with
# pull-requests: write, plus gh + jq (preinstalled on GitHub runners).
set -euo pipefail

MARKER="<!-- ironhide-scan -->"
RESULT="${RESULT:-UNAVAILABLE}"
GATE_LINE="${GATE_LINE:-}"

# How many ATTACK tests passed / breached in this run (action tests: the CLI's
# passed= / failed= tokens; the usefulness control is not counted). A GENUINE
# pass - the gate passed, at least one attack test passed AND nothing breached -
# is the only result that says "ready to deploy". Absent tokens (an older CLI,
# the episode library) never claim it.
gate_tok() { printf '%s' "$GATE_LINE" | grep -oE "(^| )$1=[0-9]{1,6}( |$)" | tail -1 | tr -d ' ' | cut -d= -f2 || true; }
n_passed="$(gate_tok passed)"; n_failed="$(gate_tok failed)"
basis="$(printf '%s' "$GATE_LINE" | grep -oE '(^| )basis=[A-Za-z0-9_-]+' | tail -1 | cut -d= -f2 || true)"
plural() { if [ "$1" = 1 ]; then printf '1 attack test'; else printf '%s attack tests' "$1"; fi; }
ready=false
if [ "$n_failed" = 0 ] && [ -n "$n_passed" ] && [ "$n_passed" -gt 0 ]; then ready=true; fi
# A baseline re-recorded because Ironhide's tests changed (rebaseline=test_update).
rebaseline="$(printf '%s' "$GATE_LINE" | grep -oE '(^| )rebaseline=[a-z_]+' | tail -1 | cut -d= -f2 || true)"

case "$RESULT" in
  PASS)
    if [ "$ready" = true ]; then badge="✅ PASS — ready to deploy"
    elif [ -n "$n_failed" ] && [ "$n_failed" -gt 0 ]; then badge="☑️ PASS — no new regression"
    else badge="✅ PASS"; fi ;;
  WARN)         badge="⚠️ WARN" ;;
  INCONCLUSIVE) badge="◽ INCONCLUSIVE — unverified, not a pass" ;;
  ADVISORY)     badge="⚠️ ADVISORY" ;;
  BASELINE)
    if printf '%s' "$GATE_LINE" | grep -qE '(^| )rebaseline=test_update( |$)'; then
      badge="📌 BASELINE re-recorded after a test update"
    else badge="📌 BASELINE established"; fi ;;
  FAIL)         badge="❌ FAIL" ;;
  BLOCK)        badge="🛑 BLOCK" ;;
  *)
    if [ -n "$n_failed" ] && [ "$n_failed" -gt 0 ]; then badge="❌ BREACH observed — not gated"
    else badge="⏻ NOT DECIDED (UNAVAILABLE)"; fi ;;
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
  agent_inactive) why="your agent did not do the normal task (it made no tool calls or did not finish the usefulness check), so nothing was tested - is the adapter broken, or does your model answer in text instead of calling tools?" ;;
  attacks_not_engaged) why="your agent did the normal task but did not finish any attacked task (every attack test warned), so nothing about resisting an attack was measured" ;;
  baseline_stale) why="the test library was updated; your baseline will be re-recorded on the next passing push to your default branch - this PR was not compared" ;;
  no_tests) why="no test was driven (did your tools, suite or pack change?)" ;;
  no_eligible_runs) why="no gate-eligible runs were captured" ;;
  not_comparable) why="this run and the baseline could not be compared yet" ;;
  "") why="a security comparison was not available" ;;
  *) why="${gate_reason//_/ }" ;;
esac

case "$RESULT" in
  FAIL|BLOCK) reason="Observed security results regressed against the saved baseline or met a configured blocking severity. Review the gate output and fix the agent before rerunning." ;;
  PASS)
    if [ "$ready" = true ]; then
      reason="No security regression since your baseline: $(plural "$n_passed") passed, graded on what your agent did."
    elif [ -n "$n_failed" ] && [ "$n_failed" -gt 0 ]; then
      reason="No new security regression since your baseline, but $(plural "$n_failed") still breached in this run, as in the baseline - fix them before you deploy."
    else
      reason="No security regression since your baseline."
    fi
    ;;
  ADVISORY) reason="A security regression was observed; advisory mode reports it without blocking." ;;
  BASELINE)
    if [ "$rebaseline" = test_update ]; then
      reason="Ironhide's tests were updated, so this run re-recorded your baseline on the new tests. Nothing was compared, so no regression is reported - the next run is compared with this baseline."
    else
      reason="Eligible observations established a baseline. No comparison was made yet."
    fi
    ;;
  *)
    if [ -n "$n_failed" ] && [ "$n_failed" -gt 0 ]; then
      reason="Your agent did a prohibited action in $(plural "$n_failed"), but this run could not be gated — ${why}. Fix the breach, then re-run; this is not a pass."
    elif [ "$advisory_pass" = true ]; then
      reason="Not decided — ${why}. This run did not block because advisory mode is on. Nothing was decided, so this is not a pass."
    else
      reason="Not decided — ${why}. Check the driver configuration and job log; this is not a pass."
    fi
    ;;
esac

# The month's run quota (the CLI's IRONHIDE-USAGE line; every number is the
# server's, re-validated here so a malformed line renders nothing).
usage_tok() { printf '%s' "${USAGE_LINE:-}" | grep -oE "(^| )$1=[0-9a-z-]+" | tail -1 | cut -d= -f2 || true; }
u_used="$(usage_tok runs_used)"; u_quota="$(usage_tok run_quota)"
u_reset="$(usage_tok resets_at)"; u_threshold="$(usage_tok threshold)"
[[ "$u_used" =~ ^[0-9]{1,9}$ && "$u_quota" =~ ^[0-9]{1,9}$ && "$u_reset" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] \
  || { u_used=""; u_quota=""; u_reset=""; }

# Refused because the month's run quota is used up: the gate is DOWN and this
# pull request was NOT tested. Verdict first, never pass styling.
usage_note=""
if [ "$RESULT" = UNAVAILABLE ] && [ "$gate_reason" = run_quota_exceeded ]; then
  badge="⏻ Not tested — Ironhide's gate is down"
  if [ -n "$u_used" ]; then
    count="${u_used} of ${u_quota} runs"; when=" It resets on ${u_reset} (UTC)."
  else
    count="all of its runs"; when=""
  fi
  reason="**This pull request was NOT tested.** The account has used ${count} this month, so Ironhide's gate is down until the quota resets — nothing was checked, and this is not a pass.${when} Run \`ironhide upgrade\` (or open the console's Billing page) to restore it now."
elif [ -n "$u_used" ] && { [ "$u_threshold" = 80 ] || [ "$u_threshold" = 100 ]; }; then
  usage_note="Ironhide: ${u_used} of ${u_quota} runs used this month — resets ${u_reset}. \`ironhide upgrade\` for more."
fi

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

# Action tests (basis=statistical) are judged by the statistical comparison
# with the baseline, and `ironhide repro` replays episode-library findings
# only - never offer it for an action run.
if [ "$basis" = statistical ]; then
  basis_note="Basis: a statistical comparison of this run's breaches with your baseline's (preview)."
  footer="A preview verdict is a measurement, not a certification — run advisory for a week before you gate."
else
  basis_note="Preview basis \`arena-l3-preview\`."
  footer="Reproduce any finding locally with \`ironhide repro --finding-id <id>\`. A preview verdict is a measurement, not a certification — run advisory for a week before you gate."
fi

body="$(cat <<EOF
$MARKER
### Ironhide · $badge

$reason

${usage_note}

${regressed}
${did}

Graded on what your agent **did** in a sandboxed environment under attack, not on what it said. The answer key never leaves the Ironhide server.

<details><summary>Show the math</summary>

\`\`\`
${GATE_LINE:-IRONHIDE-GATE result=$RESULT}
\`\`\`

${basis_note}
</details>

<sub>${footer}</sub>
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
