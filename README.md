# Ironhide Scan — GitHub Action

<!-- Last updated: 2026-10-04 (v2.3.0: plain-language PR comment; v2.2.0: advisory_pass; every input, output, env
     var and exit code below verified against action.yml and the CLI). -->

Pull the agent your PR builds into a sandboxed arena, attack it, and post a
categorical **observed-state verdict** on what the agent *did* — state changes,
tool calls, exfiltration — not on what it said about itself.

Observed-state verdicts are **preview** (`arena-l3-preview`): an honest
measurement, not a certification. Run advisory-first, watch the baseline settle,
then turn gating on.

## Verified installation

Pin a release tag, not a moving alias:

```yaml
- uses: ironhide-ai/ironhide-scan@v2.3.0
```

Set the repository variable `IRONHIDE_CLI_SHA256` to the CLI SHA-256 published
with that release. The Action downloads the `ironhide.py` artifact attached to
the release and verifies its bytes **before execution**; a missing or mismatched
digest fails the job, including in advisory mode. It never pipes an installer
into a shell.

The artifact is immutable for the life of the tag, so the digest you pin stays
valid -- it does not change when the Ironhide server is updated. If you mirror
the artifact internally, point `cli_url` at your copy and pin its digest. Never
point `cli_url` at a live server path: those bytes change on every deploy and
would break your gate.

Upgrading is deliberate: move to the new tag and update `IRONHIDE_CLI_SHA256` to
the digest that release publishes. Never take a fresh digest from the same
download in CI -- that verifies a file against itself.

> `v2` requires the Action to drive your agent: pass `adapter` or
> `agent_factory`, or set them in `.ironhide.yml`. A run with no driver
> configured fails rather than reporting a pass it never earned. The older `v1`
> tag does not drive your agent and is not a supported configuration.

## Quick start

1. Connect your agent once and grab its key: `ironhide connect` (from
   `curl -fsSL https://app.ironhideai.com/install.sh | bash`).
2. Store it as the `IRONHIDE_API_KEY` repository secret. Never commit it.
3. Create a workflow file **in your own repository** — `.github/workflows/ironhide.yml`
   is the conventional name; nothing about the action requires it. Paste this
   in:

```yaml
name: ironhide
on:
  pull_request:
  push:
    branches: [main]   # REQUIRED: this is what records the baseline

permissions:
  pull-requests: write   # the action posts the verdict as a PR comment

jobs:
  referee:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4    # must come BEFORE the action
      - uses: ironhide-ai/ironhide-scan@v2.3.0
        with:
          api_key: ${{ secrets.IRONHIDE_API_KEY }}
          adapter: your.module:agent  # replace with your actual driver
          cli_sha256: ${{ vars.IRONHIDE_CLI_SHA256 }}
          advisory_mode: true        # advisory-first: comment, don't gate
          block_on: exfiltration     # hard-block categories once gating is on
```

**The `push` trigger is not optional.** The gate compares a PR against the
`baseline_branch`'s trailing clean rate, and only a run *on* that branch records
one — a pull request is deliberately forbidden from rewriting the standard it is
being judged against. With `pull_request` alone there is never a baseline, so
every run returns `BASELINE`, exits 0 and looks green while comparing nothing.
The action posts a job warning when that happens, so you will see it rather than
infer it.

`actions/checkout` must run before the action: checkout's default `clean: true`
runs `git clean -ffdx`, which would delete the restored baseline directory.

## Customer driver

Install your project's dependencies before this Action. Set `adapter` to an
importable `module:object`, or set `agent_factory` to your tool-binding factory.
They are mutually exclusive. You can instead commit `adapter: your.module:agent`
(or `agent_factory: your.module:build_agent`) in `.ironhide.yml`; explicit Action
inputs replace that driver selection. No configured driver fails even with old
stored runs. Zero eligible observations fail even in advisory mode.

## Fork pull requests and server requirements

This Action executes the checked-out agent code with `IRONHIDE_API_KEY` in its
environment. Do not give that secret to untrusted pull-request code. Fork pull
requests normally do not receive repository secrets; an unavailable scan is not
a passing security result. Do not switch to `pull_request_target` and check out
or execute the untrusted head to bypass that restriction. Use a separately
reviewed trusted revision and an isolated runner for any secret-bearing scan.
See [GitHub's guidance](https://docs.github.com/en/actions/reference/security/securely-using-pull_request_target).

The server must enable environment routing (`IRONHIDE_ENV_ROUTING`) so the CLI
emits its measured `graded=` count. A missing count, including with routing off,
fails closed with exit 2 even in advisory mode, unless the CLI itself declared
an advisory pass (`advisory_pass=true`, see below). An unavailable gate retains its
reported `basis=` token when present; it does not invent one if absent.

In `.ironhide.yml`, driver values use the CLI's simple unquoted `key: value`
format. Quoted YAML values and inline comments are not supported; put comments
on separate lines. The current `ironhide init` template does not add a driver,
so configure `adapter` or `agent_factory` explicitly before running this Action.

## Inputs

| input | default | what it does |
| --- | --- | --- |
| `api_key` | **required** | Your agent's API key, always via `${{ secrets.IRONHIDE_API_KEY }}`. |
| `agent_id` | *(from `.ironhide.yml`)* | The connected agent's id. Optional if you commit a `.ironhide.yml` (`ironhide init`) carrying `agent_id`; otherwise set it here so a fresh checkout can resolve the agent. |
| `adapter` | from `.ironhide.yml` | Customer driver as `module:object`, passed to `--adapter`. |
| `agent_factory` | from `.ironhide.yml` | Tool-binding factory, passed to `--agent-factory`; exclusive with `adapter`. |
| `cli_sha256` | **required** | SHA-256 of the approved CLI release; verified before execution. |
| `advisory_mode` | `true` | `true` reports security regressions without blocking. An `UNAVAILABLE` the CLI marks `advisory_pass=true` - the evidence could not decide (an unconfirmed rise, a baseline too small to compare, a run left unverified by rate limits, a server-side outage) - is reported as NOT DECIDED with a warning and exits 0; it is never a pass. Configuration and setup failures still fail. `false` gates: FAIL, BLOCK per `block_on`, and any UNAVAILABLE fail the build. |
| `block_on` | `exfiltration` | Comma-separated effect categories that hard-block without statistics when `advisory_mode: false`. Add `inconclusive` if unverified runs must not merge. |
| `runs` | suite default | Samples per episode; passed as `IRONHIDE_SAMPLES`. |
| `baseline_branch` | `main` | The branch whose trailing clean rate is the baseline this PR is compared against. The first run **on** this branch records a baseline; an existing baseline is retained. Resetting it is a deliberate owner action, never an automatic CI refresh. |
| `server` | `https://app.ironhideai.com` | Ironhide server base URL. |
| `comment` | `true` | Post/update the verdict as a PR comment (needs `pull-requests: write`). |
| `profile` | *(empty)* | `pr` or `full` coverage for the episode library (see Bounded PR coverage). |
| `suite` | *(empty)* | `actions` or `library`; empty uses `.ironhide.yml` (see Action tests). |
| `pack` | *(empty)* | Action-test scenario pack: `general`, `fsm`, `crm` or `erp`. |
| `tools_file` | *(empty)* | Action tests: a JSON tool list for tools built at runtime. |

## Outputs

| output | description |
| --- | --- |
| `result` | The **gate** result: `PASS` / `FAIL` / `ADVISORY` / `BASELINE` / `UNAVAILABLE`. These five are the only values. `BLOCK`, `WARN` and `INCONCLUSIVE` are **per-episode verdicts** shown in the comment body — they are not gate results, so never match on them here. |
| `gate_line` | The full machine-readable `IRONHIDE-GATE …` line. |
| `baseline_restored` | `true` when a baseline cache matched. Inspect `result` and `graded` to verify a comparison actually ran. |

## Two different things called a "result"

**Per-episode verdicts** appear in the PR comment body, one per attacked
episode:

| verdict | meaning |
| --- | --- |
| `PASS` | Attacked; no prohibited effect observed. |
| `FAIL` | A prohibited effect was observed. |
| `BLOCK` | A hard observed effect in a `block_on` category — e.g. a canary credential left the sandbox. One observation is enough. |
| `WARN` | No prohibited effect was observed; security coverage for that run is incomplete — the episode's end-state check was not satisfied, or part of the run could not be verified. Not a gate band, and not a claim that your agent failed its task. |
| `INCONCLUSIVE` | No observed effect to grade. Reported honestly as **unverified, not a pass**. |

**The gate result** is the single value in the `IRONHIDE-GATE` line and the
`result` output. It is computed statistically over the whole sweep and has its
own, shorter vocabulary:

| gate result | meaning |
| --- | --- |
| `PASS` | Clean rate within the noise floor of the baseline. |
| `FAIL` | Clean rate fell versus baseline past the noise floor — a statistical regression over the sweep, not one bad episode. Only returned when `advisory_mode: false`. |
| `ADVISORY` | What would have been a `FAIL`, reported without breaking the build because `advisory_mode: true`. Exit 0. |
| `BASELINE` | First run for this label; this run set became the baseline. Nothing to compare yet. Exit 0. |
| `UNAVAILABLE` | Not decided: the gate could not be evaluated. Never rounded to a pass or a failure. Exit 2 — except with `advisory_mode: true` when the CLI marks it `advisory_pass=true` (the evidence could not decide; see the table below): exit 0 with a warning and a PR comment that say **NOT DECIDED** and why; the result still says `UNAVAILABLE`. A setup failure you have to fix exits 2 in both modes. |

## The gate line & exit codes

Each completed measurement prints one greppable line in the job log and at the foot of the PR
comment:

```
IRONHIDE-GATE basis=arena-l3-preview delta=-0.045 noise_floor=0.06 n=24 result=PASS planned=24 graded=24
```

The core fields are: `basis` (always
`arena-l3-preview`), `delta` (the signed change in clean rate, or the literal
`unavailable`), `noise_floor`, `n` (runs in the sweep), and `result`. Match on
`basis=arena-l3-preview` to tell this line apart from any other gate line in
your log.

An `UNAVAILABLE` line also carries `reason=<why>` and `advisory=<true|false>`,
and - only in advisory mode, only when the CLI exits 0 - `advisory_pass=true`:

```
IRONHIDE-GATE basis=statistical delta=+0 noise_floor=0.05 n=21 result=UNAVAILABLE graded=7 unverified=0 not_run=0 reason=unconfirmed advisory=true advisory_pass=true
```

The CLI decides which reasons advisory mode may let through and declares it on
the line, so a new reason never needs a new Action release. This Action honours
`advisory_pass=true` (plus `reason=run_quota_exceeded` / `action_envs_disabled`
from older CLIs); any other `UNAVAILABLE` fails.

| `reason` | advisory mode | why |
| --- | --- | --- |
| `unconfirmed`, `baseline_too_small`, `unverified`, `rate_limited`, `not_comparable` | exit 0, `advisory_pass=true`, NOT DECIDED | the evidence could not decide |
| `run_quota_exceeded`, `action_envs_disabled` | exit 0, `advisory_pass=true`, NOT DECIDED | an outage on Ironhide's side; nothing ran |
| `agent_failed_every_episode`, `nothing_graded`, `no_tests`, `no_eligible_runs`, `baseline_unreadable`, `baseline_empty`, `runs_malformed`, `pin_unknown`, `profile_identity_mismatch`, `profile_policy_mismatch`, `gate_no_result`, or a reason the CLI does not know | exit 2 | something you have to fix |

| code | meaning |
| --- | --- |
| `0` | `PASS`, `ADVISORY`, `BASELINE` — i.e. any decided result while `advisory_mode: true`, and a baseline-establishing run; with `advisory_mode: true`, also an `UNAVAILABLE` marked `advisory_pass=true` (NOT DECIDED, never a pass). |
| `1` | `FAIL` (which the server returns only when `advisory_mode: false`; `block_on` categories fail through the same code). |
| `2` | `UNAVAILABLE` / `REBASELINE_REQUIRED` — reported, never silently passed. With `advisory_mode: false`, every `UNAVAILABLE`; in advisory mode, a setup failure you have to fix. |

## How it works

The action is a thin wrapper around `ironhide test`: it installs the CLI, runs
the arena sweep against the agent registered with `ironhide connect`, grades the
observed state out of band, applies the statistical gate against the
`baseline_branch`'s trailing clean rate, posts the verdict, and exits with the
code above.

### The baseline, and how it survives between runs

The CLI writes its baseline to **`.ironhide/baseline-<label>.json`, relative to
the working directory** (`BASELINE_DIR` in `cli/ironhide.py`) — inside your
checkout, not under `~`. A CI runner is discarded after every job, so that file
survives only because the action's cache step persists it:

- **Restore** runs on every job, before `ironhide test`, and pulls the most
  recent baseline recorded for `baseline_branch`.
- **Refresh** runs only on `baseline_branch` itself. A pull request reads the
  baseline and never writes it; otherwise a PR's second run would be judged
  against the PR's own already-regressed first run, and the regression would
  vanish.

> **Fixed 2026-09-02.** Until then this step cached `~/.ironhide/baselines` — a
> path the CLI has never written, and had no code to write: `BASELINE_DIR` is
> `.ironhide`, and no path the CLI builds contains the segment `baselines`.
> The restore was a no-op, every run was a first run,
> and the gate returned `BASELINE` with exit 0 indefinitely. If you pinned this
> action before that date, take a `BASELINE` result from those runs as "nothing
> was compared", not as "nothing regressed". `tests/test_cli.py` now pins the
> action's cached path to the CLI constant, so the two cannot drift apart again.
>
> Also fixed in the same change: `ironhide test` sent the *same* label for the
> saved baseline and the current run set, and the comparison refuses two
> identically-labelled sets. Every gated run therefore returned
> `result=UNAVAILABLE` (exit 2). The saved set now carries a `baseline:` label
> prefix, applied on read as well as on write, so a baseline file an older CLI
> already wrote starts working without being deleted.

Reproduce any finding locally, deterministically:

```bash
ironhide repro --finding-id fnd_7c21a9
```

## GitLab CI

GitLab doesn't consume GitHub Actions, but the action only wraps `ironhide test`
— which runs on any CI. Mirror project: **gitlab.com/ironhide-ai/ironhide-scan**
(same CLI, same verdict, same exit codes).

Preferred — the **CI/CD component**:

```yaml
include:
  - component: $CI_SERVER_FQDN/ironhide-ai/ironhide-scan/ironhide@v1
```

Or a plain remote include:

```yaml
include:
  - remote: 'https://gitlab.com/ironhide-ai/ironhide-scan/-/raw/v1/templates/gitlab-ci.yml'
```

Set masked CI/CD variables: `IRONHIDE_API_KEY` (required) and — only to post
the verdict as an MR note — `GITLAB_TOKEN` with `api` scope (GitLab's `CI_JOB_TOKEN` can't post
notes). The gate is enforced by the job exit code with or without the token.
Set `IRONHIDE_ADVISORY: "false"` to gate.

**Nothing in the CLI reads an `IRONHIDE_AGENT_ID` environment variable**
(verified 2026-09-02: `grep -oE 'IRONHIDE_[A-Z_]+' cli/ironhide.py | sort -u`
does not list it). Identify the agent by committing a `.ironhide.yml` with
`agent_id` (`ironhide init` writes one) or by passing
`ironhide test --agent-id <id>`. The seven environment variables the CLI
actually honors are `IRONHIDE_API_KEY`, `IRONHIDE_URL`, `IRONHIDE_CONFIG`,
`IRONHIDE_HOME`, `IRONHIDE_SAMPLES`, `IRONHIDE_ADVISORY` and
`IRONHIDE_BLOCK_ON`.

That list is what the **CLI** reads. The GitLab *template* is a separate
artifact published in the mirror project (gitlab.com/ironhide-ai/ironhide-scan),
and its own docs — <https://ironhideai.com/docs/getting-started/gitlab-ci> —
document an `IRONHIDE_AGENT_ID` CI variable that the template passes through to
`ironhide test --agent-id`. If you are wiring up GitLab, follow those docs for
the template's variables.

## Notes

- Full docs: <https://ironhideai.com/docs/getting-started/github-action>
- The first sweep on `baseline_branch` establishes the baseline (`result=BASELINE`, exit 0) and is not graded against itself.


## Deliberate baseline resets

Rebaselining is a deliberate human action, never a CI step. On your local
workstation, run `ironhide login` for the account that owns the agent, then
`ironhide test --rebaseline`. The reset uses your saved owner credential;
subsequent suite requests still use the agent key. An agent-only CI job cannot
reset the baseline. Never store an owner credential in GitHub Actions.
The local baseline is retained if the server reset fails, including when the
server has no reset route or environment routing is disabled. Successful resets
record the owner account or operator in the audit trail; older `agent:` audit
rows do not identify a human.

## Bounded PR coverage (`profile`)

| input | default | what it does |
| --- | --- | --- |
| `profile` | *(empty)* | `pr` or `full`, passed to `ironhide test --profile`. Empty keeps the legacy coverage and baseline. |

Set `profile: pr` and `runs: 3` in the
Action's `with` block to request the bounded PR profile. Configure the same profile on the baseline branch so PRs
have a compatible baseline. Leaving `profile` empty preserves the existing
coverage and baseline behavior; upgrades do not silently select fewer episodes.

For example, keep the quick-start workflow's **both** `pull_request` and
`push: branches: [main]` triggers, then use these steps after checkout and installing your agent dependencies.
Both steps pin the same release and CLI digest:

```yaml
- uses: ironhide-ai/ironhide-scan@v2.3.0
  with:
    api_key: ${{ secrets.IRONHIDE_API_KEY }}
    adapter: your.module:agent  # replace with your actual driver
    cli_sha256: ${{ vars.IRONHIDE_CLI_SHA256 }}
    advisory_mode: false
    profile: pr
    runs: 3
    baseline_branch: main
- uses: ironhide-ai/ironhide-scan@v2.3.0
  if: github.event_name == 'push' && github.ref_name == 'main'
  with:
    api_key: ${{ secrets.IRONHIDE_API_KEY }}
    adapter: your.module:agent  # replace with your actual driver
    cli_sha256: ${{ vars.IRONHIDE_CLI_SHA256 }}
    advisory_mode: false
    profile: full
    runs: 3
    baseline_branch: main
```

The first step establishes the `pr` baseline on its first main run, preserves
that baseline in the cache, and compares subsequent runs against it. The second
independently establishes and preserves the `full` baseline. Neither step
automatically replaces an existing baseline or refreshes profile membership.
Before a release, run `profile: full` against the release candidate using that
same baseline branch and driver context; confirm a comparison occurred. Its
first run may only establish a baseline. A workflow that runs only `full` on
main leaves `pr` without a baseline and cannot gate those PR runs.

Use `profile: full` before a release and for scheduled full sweeps. Full means
the complete **routed** population: unsupported runner channels still appear
as NOT RUN. Keep a separate baseline-branch run for each profile you use; a
`full` baseline cannot supply the comparison for `pr`.

The equivalent CLI choices are `ironhide test --profile pr` and
`ironhide test --profile full`, with your usual driver arguments. The CLI
prints the chosen coverage and omitted counts before running. The gate line
and PR comment retain `profile=pr|full` and `profile_omitted=N`; total `not_run`
includes profile omissions. NOT RUN is not a pass and is excluded from the
gate's selected population. A server that cannot support a requested profile
must refuse it; do not remove the option to silently retry with different coverage.

Explicit-profile baselines live under
`.ironhide/profiles-v1/<context-sha>.json`, scoped by server, agent, label and
profile context. The Action caches `.ironhide` using separate `pr`, `full` and
legacy namespaces. Establish the first baseline for each explicit profile;
the first run reports `BASELINE`, which means no comparison took place.
`--profile` with `--rebaseline` currently refuses: profile-only refresh is tracked
in [CRU-157](https://linear.app/ironhide-services/issue/CRU-157).

This opt-in wiring does not establish a five-minute runner budget, security
representativeness, or held-out secrecy approval. Those require the separate
reference-runner measurements and policy review; no speed claim is made here.

## Action tests

Action tests are new in v2.1.0. They test what your agent *does* (send, pay,
change, delete, grant, remember, run code) using its own tool list. Three inputs
control them, all optional; an empty value defers to `.ironhide.yml`.

| input | default | what it does |
| --- | --- | --- |
| `suite` | *(empty)* | `actions` tests what your agent does (send, pay, change, delete, grant, remember, run code...) with your own tool list; `library` is the episode library. |
| `pack` | *(empty)* | The scenario pack for action tests: `general`, `fsm`, `crm` or `erp`. |
| `tools_file` | *(empty)* | A JSON tool list for tools built at runtime: an MCP `tools/list` result, OpenAI function schemas, or `{name, params}` rows. |

Action tests save `.ironhide/actions-suite-<label>.json` on the baseline
branch's first run. The cached `.ironhide/` directory carries it to pull
requests, which then re-run those tests on fresh instances and gate with
`basis=statistical`: a test fails the gate only when its breach rate rose
against the baseline's counts and that held on a re-run, or when a critical
action the baseline never saw happened. The gate line keeps the same
`result=` and `graded=` fields this Action reads.
