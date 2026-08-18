# quality-gate-check

Run a gate script inside a Docker image and expose the result — captures the metric output even when the gate fails, so downstream steps always have numbers to report.

## What it does

Implements the `continue-on-error` / re-raise pattern for quality gates: run a bash script inside a Docker container (with the workspace mounted), capture whatever metric file it writes, then exit non-zero if and only if the gate actually failed. The key property is that the metric value is always captured — even on a gate failure — so a downstream comment-posting step never has to render "N/A" just because the gate was red.

**This action does not fail the job.** It uses `continue-on-error: true` internally and surfaces `passed` as an output. The caller decides when to fail:

```yaml
- name: Fail if any gate failed
  if: steps.coverage-gate.outputs.passed != 'success' || steps.pylint-gate.outputs.passed != 'success'
  run: exit 1
```

## How it works

| Step | What happens |
|---|---|
| 1. Run gate | `docker run` mounts `$GITHUB_WORKSPACE` as `/app`, injects the baseline via the named env var, and runs `bash <gate-script>`. Sets `GATE_FAILED=1` if the container exits non-zero, then reads the metric file and writes it to `GITHUB_OUTPUT` before re-raising the failure. `continue-on-error: true` means the job continues regardless. |
| 2. Capture gate outcome | Runs `if: always()` so it executes even when step 1 failed. Writes `steps.run.outcome` (`'success'` or `'failure'`) as the `passed` output. |

## Inputs

| Input | Required | Default | Description |
|-------|----------|---------|-------------|
| `docker-image` | yes | — | Full image reference to run the gate inside. Must already be pulled or available on the runner — this action does not pull it. |
| `gate-script` | yes | — | Path to the gate script inside the container, relative to the mounted workspace root (e.g. `ci_scripts/check_coverage_gate.sh`) |
| `output-file` | yes | — | File the gate script writes its metric to, relative to the workspace root (e.g. `coverage_pct.txt`) |
| `baseline-var` | yes | — | Name of the environment variable to inject into the container (e.g. `COVERAGE_BASELINE`) |
| `baseline-value` | yes | — | Value to inject via `baseline-var` |

## Outputs

| Output | Description |
|--------|-------------|
| `value` | Metric value read from `output-file`. Empty string if the gate crashed before writing it. |
| `passed` | `'success'` if the gate passed, `'failure'` if it failed or crashed. |

## Example

```yaml
steps:
  # ... (checkout, setup-aws, resolve baseline, run tests) ...

  - name: Check coverage against baseline
    id: coverage-gate
    uses: hakimo-ai/actions/quality-gate-check@v1
    with:
      docker-image: ${{ env.DOCKER }}
      gate-script: ci_scripts/check_coverage_gate.sh
      output-file: coverage_pct.txt
      baseline-var: COVERAGE_BASELINE
      baseline-value: ${{ steps.baseline.outputs.coverage_baseline }}

  - name: Check pylint score against baseline
    id: pylint-gate
    uses: hakimo-ai/actions/quality-gate-check@v1
    with:
      docker-image: ${{ env.DOCKER }}
      gate-script: ci_scripts/check_pylint_gate.sh
      output-file: pylint_score.txt
      baseline-var: PYLINT_BASELINE
      baseline-value: ${{ steps.baseline.outputs.pylint_baseline }}

  - name: Fail if any gate failed
    if: always() && (steps.coverage-gate.outputs.passed != 'success' || steps.pylint-gate.outputs.passed != 'success')
    run: exit 1

# Use the outputs downstream:
# steps.coverage-gate.outputs.value  → e.g. "87.3"
# steps.pylint-gate.outputs.value    → e.g. "9.12"
# steps.coverage-gate.outputs.passed → "success" or "failure"
```

## Prerequisites

- The Docker image must already be available on the runner (logged in to the registry, image built or pulled in a prior step).
- The gate script must write its metric to `output-file` relative to the workspace root inside the container (which is mounted as `/app`).
- The workspace must be checked out so the gate script and any supporting files exist in `$GITHUB_WORKSPACE`.

## Security guardrails

- **`gate-script` and `docker-image` are interpolated directly into the bash command.** This action is designed for internal use where both inputs come from trusted, version-controlled values (committed CI scripts and ECR images built from code review). Do not pass user-controlled values for either input.
- **The container has read/write access to the full workspace** (`-v "$GITHUB_WORKSPACE":/app`). A malicious gate script could modify files in the checkout. Only run gate scripts from trusted, reviewed sources.
- **No AWS credentials or secrets are injected into the container.** The container only receives the baseline value via `baseline-var`. The image must already contain the dependencies the gate script needs.
