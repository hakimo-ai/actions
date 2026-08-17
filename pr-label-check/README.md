# pr-label-check

Fail a job if a pull request has no labels assigned.

## What it does

Extracted from a near-identical `pr-label-check.yml` duplicated in **3 of 4** consumer repos (`ai-engine`, `vision`, `hakimo-ui`) — all wrapping `joerick/pr-labels-action` with the same "at least one label" check, but pinned to a **floating tag**, inconsistently (`@v1.0.6` in one repo, `@v1.0.9` in the other two). This action fixes both the duplication and the SHA-pinning gap in one move — a version bump here now goes through review instead of a maintainer silently redirecting a tag underneath every caller at once.

Deliberately minimal by design: no severity levels, no PR comment, no findings gate like `security-scan`/`lint-check`/`sbom-scan` have. The whole point of this action *is* the check — there's no broader "scan" concept that needs a crash-vs-findings distinction.

## How it works

| Step | What happens |
|---|---|
| 1. Get PR labels | `joerick/pr-labels-action` reads the current PR's labels into its `labels` output. |
| 2. Verify PR has at least one label | Fails the job with `::error::` (including `hint`) if that output is empty. |

## Inputs

| Input | Required | Default | Description |
|-------|----------|---------|-------------|
| `hint` | no | `Add a label (e.g. fix, feat, chore) or use a conventional-commit prefix in your PR title if this repo auto-labels from that.` | Extra hint text shown in the failure message when no labels are found |

## Outputs

None.

## Example

```yaml
on:
  pull_request:
    types: [opened, synchronize, reopened, edited, labeled, unlabeled]
    branches:
      - master

permissions:
  pull-requests: read

jobs:
  check-pr-label:
    runs-on: ubuntu-latest
    timeout-minutes: 2
    steps:
      - uses: hakimo-ai/actions/pr-label-check@v1
```

> **This action only makes sense on `pull_request`/`pull_request_target` events** — `joerick/pr-labels-action` has nothing to read on a `push` or other event. That's not enforced inside the action itself (turning "wrong event" into a silent no-op wouldn't be any clearer than the error you'd get from the underlying action), so make sure the caller workflow's `on:` only triggers this on PR events, as in the example above.

## Security guardrails

- **Lowest-risk action in this repo.** It only reads PR metadata (labels) and fails/passes a job — no code execution, no AWS access, no write access to anything beyond the job's own pass/fail status. `permissions: pull-requests: read` is all it needs.
- No image, no target-repo code, no credentials involved — there's no meaningful "pwn request" surface here the way there is for `docker-build-push`/`lint-check`/`sbom-scan`.
