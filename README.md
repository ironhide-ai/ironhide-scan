# Ironhide Scan — GitHub Action

<!-- Last updated: 2026-09-02 (every input, output, env var and exit code below
     verified against action.yml and the CLI). -->

Pull the agent your PR builds into a sandboxed arena, attack it, and post a
categorical **observed-state verdict** on what the agent *did* — state changes,
tool calls, exfiltration — not on what it said about itself.

Observed-state verdicts are **preview** (`arena-l3-preview`): an honest
measurement, not a certification. Run advisory-first, watch the baseline settle,
then turn gating on.

## Release status and verified installation

The driver-enabled Action release and its versioned CLI artifact are not yet
published. This integration must remain unreleased until the approved tag and
digest are available;
the existing public `v1` tag is not evidence that these new inputs are available.
Use an approved release tag or immutable commit after publication.

Set the repository variable `IRONHIDE_CLI_SHA256` to the CLI SHA-256 supplied
with that approved release. The Action downloads `/cli/ironhide.py` from `server`
and verifies its bytes **before execution**. Missing or mismatched digests fail
the job, including in advisory mode. It never executes the mutable installer.
A server update that changes CLI bytes requires an explicitly reviewed digest
update; do not calculate and trust a fresh digest from the same download in CI.
Release checksum retrieval and publication remain release-owner tasks.

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
      - uses: ironhide-ai/ironhide-scan@v2.0.0
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
fails closed with exit 2 even in advisory mode. An unavailable gate retains its
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
| `advisory_mode` | `true` | `true` reports security regressions without blocking; configuration and unavailable results still fail. `false` gates: FAIL, and BLOCK per `block_on`, fail the build. |
| `block_on` | `exfiltration` | Comma-separated effect categories that hard-block without statistics when `advisory_mode: false`. Add `inconclusive` if unverified runs must not merge. |
| `runs` | suite default | Samples per episode; passed as `IRONHIDE_SAMPLES`. |
| `baseline_branch` | `main` | The branch whose trailing clean rate is the baseline this PR is compared against. The first run **on** this branch records a baseline; an existing baseline is retained. Resetting it is a deliberate owner action, never an automatic CI refresh. |
| `server` | `https://app.ironhideai.com` | Ironhide server base URL. |
| `comment` | `true` | Post/update the verdict as a PR comment (needs `pull-requests: write`). |

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
| `UNAVAILABLE` | The gate could not be evaluated. Exit 2 — never rounded to a pass or a failure. |

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

| code | meaning |
| --- | --- |
| `0` | `PASS`, `ADVISORY`, `BASELINE` — i.e. any result while `advisory_mode: true`, and a baseline-establishing run. |
| `1` | `FAIL` (which the server returns only when `advisory_mode: false`; `block_on` categories fail through the same code). |
| `2` | Ironhide unavailable — reported, never silently passed. |

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
