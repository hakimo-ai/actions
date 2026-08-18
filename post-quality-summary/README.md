# post-quality-summary

Post or update the quality gate results as a PR comment. No-op on non-pull-request events.

## What it does

Reads `quality_baseline.json` from the checked-out repo for tolerances, combines them with the baseline values and gate outcomes passed in as inputs, and upserts a single "Quality Gate Summary" comment on the PR. Updates the existing comment rather than creating a new one on every push (matched via a fixed header string, paginating through all existing comments so it never misses its own prior comment on a long-lived PR).

## How it works

| Step | What happens |
|---|---|
| 1. Guard | Skips the action entirely on non-`pull_request`/`pull_request_target` events — safe to call from jobs that trigger on both push and pull_request. |
| 2. Build comment body | Reads `quality_baseline.json` for tolerances. Uses `num()` with fallback so a cancelled or crashed upstream gate never renders NaN. Builds a two-row status table (Coverage / Pylint) with current value, baseline, tolerance, and pass/fail. Appends a source annotation (`best measured on master` vs `committed seed`) and a context-sensitive footer emoji. |
| 3. Paginate existing comments | Uses `github.paginate` (not a single-page `listComments`) to find the prior bot comment on PRs with >30 comments — avoids duplicate comments on active PRs. |
| 4. Upsert comment | Updates the existing bot comment if found, creates a new one otherwise. |

## Inputs

| Input | Required | Default | Description |
|-------|----------|---------|-------------|
| `github-token` | yes | — | GitHub token with `pull-requests: write` permission |
| `coverage-pct` | no | `''` | Measured coverage percentage (e.g. `87.3`). Empty string renders as `N/A`. |
| `pylint-score` | no | `''` | Measured pylint score (e.g. `9.12`). Empty string renders as `N/A`. |
| `coverage-passed` | no | `''` | `'success'` or `'failure'` — the outcome of the coverage gate step |
| `pylint-passed` | no | `''` | `'success'` or `'failure'` — the outcome of the pylint gate step |
| `baseline-coverage` | no | `''` | Coverage baseline (numeric string). Falls back to `quality_baseline.json` seed if empty or non-numeric. |
| `baseline-pylint` | no | `''` | Pylint baseline (numeric string). Falls back to `quality_baseline.json` seed if empty or non-numeric. |
| `baseline-source` | no | `''` | `'published'` if the baseline came from S3; anything else shows as "committed seed in quality_baseline.json". |
| `baseline-commit` | no | `''` | Short SHA of the commit that last raised the published baseline — shown in the footer when `baseline-source` is `'published'`. |

## Outputs

None.

## Example

```yaml
jobs:
  lint-test:
    # ... build, test, gate steps ...
    outputs:
      coverage_pct:       ${{ steps.coverage-gate.outputs.value }}
      pylint_score:       ${{ steps.pylint-gate.outputs.value }}
      coverage_passed:    ${{ steps.coverage-gate.outputs.passed }}
      pylint_passed:      ${{ steps.pylint-gate.outputs.passed }}
      baseline_coverage:  ${{ steps.baseline.outputs.coverage_baseline }}
      baseline_pylint:    ${{ steps.baseline.outputs.pylint_baseline }}
      baseline_source:    ${{ steps.baseline.outputs.baseline_source }}
      baseline_commit:    ${{ steps.baseline.outputs.baseline_commit }}

  post-pr-summary:
    runs-on: ubuntu-latest
    needs: lint-test
    if: always() && github.event_name == 'pull_request'
    permissions:
      contents: read
      pull-requests: write
    steps:
      - uses: actions/checkout@11d5960a326750d5838078e36cf38b85af677262  # v4.4.0

      - uses: hakimo-ai/actions/post-quality-summary@v1
        with:
          github-token:     ${{ secrets.GITHUB_TOKEN }}
          coverage-pct:     ${{ needs.lint-test.outputs.coverage_pct }}
          pylint-score:     ${{ needs.lint-test.outputs.pylint_score }}
          coverage-passed:  ${{ needs.lint-test.outputs.coverage_passed }}
          pylint-passed:    ${{ needs.lint-test.outputs.pylint_passed }}
          baseline-coverage: ${{ needs.lint-test.outputs.baseline_coverage }}
          baseline-pylint:   ${{ needs.lint-test.outputs.baseline_pylint }}
          baseline-source:   ${{ needs.lint-test.outputs.baseline_source }}
          baseline-commit:   ${{ needs.lint-test.outputs.baseline_commit }}
```

## Prerequisites

- The calling job must check out the repo before calling this action — `quality_baseline.json` must exist in the workspace (it's a committed file in the consuming repo, not part of this action).
- Requires `permissions: pull-requests: write` on the calling job.
- Designed to be called with `if: always()` so the comment still posts even when the gate failed — that's the point.

## Security guardrails

- **No code execution, no AWS access, no Docker.** This action only makes GitHub API calls and reads one committed JSON file. Lowest risk action in this repo after `pr-label-check`.
- **`pull_request_target` callers**: this action posts a PR comment using the `github-token` passed in. If the calling job uses `pull_request_target` with elevated permissions and also checks out a fork's code, a malicious `quality_baseline.json` in the fork could cause unexpected behavior (the action reads it from the checked-out workspace). Use `pull_request` instead unless you specifically need `pull_request_target`'s elevated access.
