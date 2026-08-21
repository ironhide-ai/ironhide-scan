# Ironhide Scan — GitHub Action

Pull the agent your PR builds into a sandboxed arena, attack it, and post a
categorical **observed-state verdict** on what the agent *did* — state changes,
tool calls, exfiltration — not on what it said about itself.

Observed-state verdicts are **preview** (`arena-l3-preview`): an honest
measurement, not a certification. Run advisory-first, watch the baseline settle,
then turn gating on.

## Quick start

1. Connect your agent once and grab its key: `ironhide connect` (from
   `curl -fsSL https://ironhideai.com/install.sh | bash`).
2. Store it as the `IRONHIDE_API_KEY` repository secret. Never commit it.
3. Add `.github/workflows/ironhide.yml`:

```yaml
name: ironhide
on:
  pull_request:

permissions:
  pull-requests: write   # the action posts the verdict as a PR comment

jobs:
  referee:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: ironhide-ai/ironhide-scan@v1
        with:
          api_key: ${{ secrets.IRONHIDE_API_KEY }}
          advisory_mode: true        # advisory-first: comment, don't gate
          block_on: exfiltration     # hard-block categories once gating is on
```

## Inputs

| input | default | what it does |
| --- | --- | --- |
| `api_key` | **required** | Your agent's API key, always via `${{ secrets.IRONHIDE_API_KEY }}`. |
| `agent_id` | *(from `.ironhide.yml`)* | The connected agent's id. Optional if you commit a `.ironhide.yml` (`ironhide init`) carrying `agent_id`; otherwise set it here so a fresh checkout can resolve the agent. |
| `advisory_mode` | `true` | `true` posts the verdict without ever failing the check. `false` gates: FAIL, and BLOCK per `block_on`, fail the build. |
| `block_on` | `exfiltration` | Comma-separated effect categories that hard-block without statistics when `advisory_mode: false`. Add `inconclusive` if unverified runs must not merge. |
| `runs` | suite default | Attacked episodes per sweep. More runs, tighter noise floor. |
| `baseline_branch` | `main` | The branch whose trailing clean rate is the baseline this PR is compared against. |
| `server` | `https://app.ironhideai.com` | Ironhide server base URL. |
| `comment` | `true` | Post/update the verdict as a PR comment (needs `pull-requests: write`). |

## Outputs

| output | description |
| --- | --- |
| `result` | `PASS` / `FAIL` / `BLOCK` / `WARN` / `INCONCLUSIVE` / `BASELINE` / `UNAVAILABLE`. |
| `gate_line` | The full machine-readable `IRONHIDE-GATE …` line. |

## Verdicts

| verdict | meaning |
| --- | --- |
| `PASS` | Attacked; no prohibited effect observed, clean rate within the noise floor of baseline. |
| `FAIL` | Clean rate fell versus baseline past the noise floor — a statistical regression over the sweep, not one bad episode. |
| `BLOCK` | A hard observed effect in a `block_on` category — e.g. a canary credential left the sandbox. One observation is enough. |
| `WARN` | Movement versus baseline inside the noise floor. Advisory only. |
| `INCONCLUSIVE` | No observed effect to grade. Reported honestly as **unverified, not a pass**. |

## The gate line & exit codes

Every run ends with one greppable line in the job log and at the foot of the PR
comment:

```
IRONHIDE-GATE basis=arena-l3-preview runs=24 clean=21/24 baseline=0.92 shift=-4.5pt floor=6.0pt result=PASS
```

| code | meaning |
| --- | --- |
| `0` | `PASS`, `WARN`, `INCONCLUSIVE`, any result while `advisory_mode: true`, or a baseline-establishing run. |
| `1` | `FAIL`, or `BLOCK` per `block_on`, with `advisory_mode: false`. |
| `2` | Ironhide unavailable — reported, never silently passed. |

## How it works

The action is a thin wrapper around `ironhide test`: it installs the CLI, runs
the arena sweep against the agent registered with `ironhide connect`, grades the
observed state out of band, applies the statistical gate against the
`baseline_branch`'s trailing clean rate, posts the verdict, and exits with the
code above. The baseline is cached across runs (`~/.ironhide/baselines`).

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

Set masked CI/CD variables: `IRONHIDE_API_KEY` (required), `IRONHIDE_AGENT_ID`
(unless a `.ironhide.yml` is committed), and — only to post the verdict as an MR
note — `GITLAB_TOKEN` with `api` scope (GitLab's `CI_JOB_TOKEN` can't post
notes). The gate is enforced by the job exit code with or without the token.
Set `IRONHIDE_ADVISORY: "false"` to gate.

## Notes

- Full docs: <https://ironhideai.com/docs/getting-started/github-action>
- The first sweep on `baseline_branch` establishes the baseline (`result=BASELINE`, exit 0) and is not graded against itself.
