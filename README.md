# hakimo-ai/actions

Shared composite-action library for Hakimo CI pipelines. All actions are versioned together — pin to a release tag in callers.

```yaml
uses: hakimo-ai/actions/<action-name>@v1
```

---

## Local setup

```bash
pip install pre-commit  # or: brew install pre-commit
pre-commit install
```

This wires up a pre-commit hook that runs `check-yaml` (catches YAML syntax errors — the `mapping values are not allowed here` class of bug that only shows up once GitHub tries to parse the file) and `yamllint` (style: indentation, duplicate keys, etc.) against every `action.yml`/`.yml` file before each commit. Config lives in `.pre-commit-config.yaml` / `.yamllint.yml`; both are pinned to a full commit SHA of the hook repo, same rationale as the external-action pinning below.

Note: `actionlint` (the GitHub Actions *workflow*-file linter) is deliberately **not** used here — it only understands `.github/workflows/*.yml` schema (`on:`/`jobs:`) and misparses standalone composite `action.yml` files (this repo's entire content) as broken workflows.

---

## Why commit SHA pinning?

Every external action referenced inside this repo (`aws-actions/configure-aws-credentials`, `docker/metadata-action`, etc.) is pinned to a **full commit SHA** rather than a version tag like `@v4`.

**The problem with tags:**
Git tags are mutable. A maintainer can — intentionally or by mistake — force-push a tag like `@v4` to point at a completely different commit. If that happens, every workflow across the org silently starts running new, untested code on the next CI run, with no diff, no PR, and no review. This is a known supply-chain attack vector (it's how the `tj-actions/changed-files` incident in 2025 played out across thousands of repos).

**What SHA pinning does:**
A commit SHA is immutable — it is the content. Once we write `uses: aws-actions/configure-aws-credentials@7474bc4...`, that exact commit is what runs forever, regardless of what the maintainer does to the tag afterward. The only way it changes is if someone edits this file and opens a PR here, which goes through review.

**The tradeoff:**
SHAs are not human-readable on their own, so every pin in this repo includes a comment with the version it corresponds to (e.g. `# v4.3.1`). When updating, you replace both the SHA and the comment together.

---

## Pinned dependency versions

All versions stay on the same major as `ai-engine`'s existing workflows to avoid breaking changes on migration.

| External action | Version | Full commit SHA |
|----------------|---------|----------------|
| `aws-actions/configure-aws-credentials` | v6.2.3 | `e6de054238d6b7531b4efff3b6587d9aade6a06c` |
| `aws-actions/amazon-ecr-login` | v2.1.6 | `b040164c4934333d597f3f9c67502ff28f814e9c` |
| `docker/metadata-action` | v6.2.0 | `dc802804100637a589fabce1cb79ff13a1411302` |
| `useblacksmith/setup-docker-builder` | v1.12.0 | `af73aad1881ac50c474addd444fe279cac9be318` |
| `useblacksmith/build-push-action` | v2.3.0 | `9b0579bbec7a6cad2f171596c57e7ac1e7658850` |
| `actions/checkout` *(callers)* | v4.3.1 | `34e114876b0b11c390a56381ad16ebd13914f8d5` |

**How to update a dependency:**
1. Find the new release tag on the action's GitHub repo
2. Get its SHA: `gh api repos/<owner>/<repo>/git/ref/tags/<tag> --jq '.object.sha'`
3. Replace the SHA and the `# vX.Y.Z` comment in the relevant `action.yml`
4. Open a PR — CI on this repo will validate it before it can be tagged and released

---

## Actions

### `setup-ecr`

Wraps `configure-aws-credentials` + `amazon-ecr-login` into a single step. Used anywhere a workflow needs AWS access or ECR access without doing a full Docker build.

**Inputs**

| Input | Required | Description |
|-------|----------|-------------|
| `role-to-assume` | yes | IAM role ARN to assume via OIDC |
| `aws-region` | yes | AWS region (e.g. `us-west-2`) |

**Example**

```yaml
permissions:
  id-token: write
  contents: read

steps:
  - uses: hakimo-ai/actions/setup-ecr@v1
    with:
      role-to-assume: ${{ secrets.AWS_ROLE_ARN }}
      aws-region: ${{ vars.AWS_REGION }}
```

> Requires `id-token: write` so the OIDC token can be exchanged for AWS credentials.

---

### `docker-build-push`

Full ECR auth + Docker metadata + build + push in one step. Internally calls `setup-ecr`, so you do not need a separate `setup-ecr` step when using this action.

Replaces the 5-step boilerplate (`configure-aws-credentials` → `amazon-ecr-login` → `metadata-action` → `setup-docker-builder` → `build-push-action`) that was copy-pasted across every `build-docker-*.yml` in `ai-engine`.

**Inputs**

| Input | Required | Default | Description |
|-------|----------|---------|-------------|
| `role-to-assume` | yes | — | IAM role ARN |
| `aws-region` | yes | — | AWS region |
| `ecr-registry` | yes | — | ECR registry URL |
| `ecr-repo` | yes | — | ECR repository name (e.g. `hakimo-vision/alarm-group-etl`) |
| `dockerfile` | no | `Dockerfile` | Path to Dockerfile |
| `context` | no | `.` | Docker build context |
| `tag` | no | `''` | Explicit tag (e.g. `base-latest`). When empty: `master-{SHA}` on master, `dev-{SHA}` on branches |
| `latest-on-master` | no | `true` | Also push a `latest` tag on master when no explicit tag is set. Set to `false` for images that use their own fixed tag (e.g. `base-latest`) |

**Outputs**

| Output | Description |
|--------|-------------|
| `tags` | Newline-separated list of all pushed image tags |

**Example**

```yaml
permissions:
  id-token: write
  contents: read

steps:
  - uses: actions/checkout@v3

  - id: build
    uses: hakimo-ai/actions/docker-build-push@v1
    with:
      role-to-assume: ${{ secrets.AWS_ROLE_ARN }}
      aws-region: ${{ vars.AWS_REGION }}
      ecr-registry: ${{ secrets.ECR_REGISTRY }}
      ecr-repo: hakimo-vision/alarm-group-etl
      dockerfile: ./Dockerfile.alarmgroups.etl
      tag: ${{ inputs.tag }}

  - run: echo "Pushed ${{ steps.build.outputs.tags }}"
```

---

### `security-scan`

Language-aware security scan. Auto-detects what's in the repo (Python, Node/JS/TS, Rust, C#/.NET, Dockerfile/Terraform/K8s manifests) and runs the right open-source scanners without per-language configuration. No GitHub Advanced Security dependency — no CodeQL, no SARIF upload to the Security tab (the org doesn't have a GHAS license).

- **Grype** (`anchore/scan-action`, path-scan mode) — dependency CVEs. Same tool already used for image scanning in `ai-engine/tag_bump.yml` (`anchore/sbom-action` + `anchore/scan-action`), now applied at source level instead of Trivy, to keep one vuln-scanning tool org-wide. Auto-detects Python, npm/yarn, Cargo, and NuGet manifests via Syft's catalogers.
- **Trivy** (`fs` scan, `secret,misconfig` scanners — vuln scanning is Grype's job) — secrets and IaC/Dockerfile/K8s misconfig, in one pass. Chosen over a dedicated secrets tool (e.g. Gitleaks) to keep the scan fast: it's already running for misconfig, so enabling its secret scanner is free (no extra image pull/step), at the cost of only scanning the current working tree rather than full git history. This is also what actually scans `deploy`, which is almost entirely Kustomize/K8s YAML.
- **Semgrep** (`--config auto`) — SAST, auto-selects rulesets per language. Only runs if Python, Node, Rust, or C# source is detected (skipped for pure-manifest repos like `deploy`). The image is cached (`actions/cache`, keyed on the pinned Semgrep version) and loaded via `docker load` instead of pulled fresh every run — the pipeline was built to be fast, and a cold image pull was the single largest per-run cost outside the scans themselves.

All three scanners report findings without failing the job by default (`fail-on-findings: false`). Since there's no Security-tab integration, results are written as JSON (`grype-results.json`, `trivy-results.json`, `semgrep-results.json`) and uploaded as a `security-scan-reports` workflow artifact — skipped when there's nothing to show (zero findings and nothing failed), so the common case doesn't burn artifact storage on every PR.

**A scanner crashing (tool error, not "found findings") always fails the job**, regardless of `fail-on-findings`. Each scanner (Grype/Trivy/Semgrep) runs with `continue-on-error: true` so one crashing doesn't block the others from running, but the "Evaluate findings" step checks each one's actual outcome and fails loudly — with a `::error::` annotation naming which scanner(s) failed — if any of them didn't complete. This matters because `fail-on-findings: false` (the default) means the PR comment, not the job's red/green status, is what most reviewers will actually look at — so a crash has to be visible *in that comment* ("Security scan — incomplete (Grype failed to run)") rather than silently rendering as "0 findings," which would look identical to a clean scan.

On `pull_request`/`pull_request_target` events, the action also posts (and on re-runs, updates in place — it won't spam a new comment on every push, and correctly paginates through all existing PR comments to find its own) a single PR comment summarizing findings per scanner, with a link to the full JSON reports artifact. This is centralized here in the composite action, not per-caller — every repo that uses `security-scan` on a PR trigger gets PR comments automatically, no extra workflow logic needed in `ai-engine`/`vision`/`hakimo-ui`/`deploy` beyond the `pull-requests: write` permission below. It's a no-op (skipped, no error) on `push` or other non-PR events.

**The comment itself stays compact.** The always-visible part is just the per-scanner count table (3-4 lines). The actual individual findings — CVE IDs, secret rule IDs, misconfig IDs, Semgrep check IDs, each with severity and location — are pulled straight out of the JSON reports and listed most-severe-first inside a collapsed `<details>` block (`Top N finding(s) — M more in the full report`), so a reviewer sees a one-glance summary by default and can expand for real detail without leaving GitHub or downloading the artifact. Capped at `max-comment-findings` (default 10) to keep the comment from growing unbounded on a badly-behaved repo with hundreds of findings; the rest are still in the full JSON artifact.

**Inputs**

| Input | Required | Default | Description |
|-------|----------|---------|-------------|
| `path` | no | `.` | Root path to scan |
| `severity-cutoff` | no | `medium` | Minimum severity to treat as a finding (`negligible`, `low`, `medium`, `high`, `critical`) — drives both Grype's cutoff and Trivy's severity list |
| `semgrep-config` | no | `auto` | Semgrep ruleset config (e.g. `auto`, `p/python`, `p/ci`) |
| `fail-on-findings` | no | `false` | Fail the job if any scanner reports findings (a scanner crash always fails the job regardless of this setting) |
| `comment-on-pr` | no | `true` | Post/update a PR comment with the findings summary. No-op outside `pull_request`/`pull_request_target` events |
| `max-comment-findings` | no | `10` | Max number of individual findings (most severe first) to list in the PR comment's collapsed detail section |

**Outputs**

| Output | Description |
|--------|--------------|
| `findings-count` | Total number of findings across all scanners |

**Example**

```yaml
permissions:
  contents: read
  pull-requests: write   # required for the PR comment (comment-on-pr, default true)

steps:
  - uses: actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5  # v4.3.1
    with:
      fetch-depth: 0

  - uses: hakimo-ai/actions/security-scan@v1
    with:
      path: .
      severity-cutoff: 'medium'
      fail-on-findings: 'false'
```

> Set `comment-on-pr: 'false'` and drop `pull-requests: write` for workflows that only ever run on `push` (no PR to comment on), or that just want the step summary / artifact without a PR comment.

---

## Versioning

All actions in this repo share a single version tag (`v1`, `v2`, …). When any action changes, the tag is bumped and callers are updated in a follow-up PR in `ai-engine`.

- Always pin callers to a tag: `uses: hakimo-ai/actions/setup-ecr@v1`
- Never use `@main` — a breaking change on main would affect every in-flight run immediately with no warning
- To release a new version: commit to `main`, then `git tag v2 && git push origin v2`
