# hakimo-ai/actions

Shared composite-action library for Hakimo CI pipelines. All actions are versioned together — pin to a release tag in callers.

```yaml
uses: hakimo-ai/actions/<action-name>@v1
```

---

## Security guardrails — read this before contributing or using these actions

**This repo is public.** Anything committed here (code, comments, commit messages, PR discussions) is visible to anyone on the internet, indefinitely, even after a later revert. A few rules that follow from that:

- **Never commit secrets, credentials, internal hostnames/IPs, AWS account IDs, or IAM role ARNs.** Every example in this repo uses `${{ secrets.* }}`/`${{ vars.* }}` placeholders for a reason — copy that pattern, don't hardcode real values, even "just for testing."
- **`CLAUDE.md` (if present in your checkout) is gitignored on purpose.** It carries internal architecture/planning context that isn't meant to be public. Don't remove it from `.gitignore`.
- **Treat every PR here as reviewable by anyone, forever.** Don't paste internal Slack threads, ticket numbers with sensitive context, or infrastructure details into commit messages or PR descriptions beyond what's needed to explain the change.
- **Review dependency-bump PRs like any other code change, not a rubber stamp.** The whole point of [SHA-pinning](#why-commit-sha-pinning) is that a version bump is visible in a diff — actually look at it. Skipping that review defeats the protection.

### "Pwn requests" — the pattern to watch for across every action here

Several actions in this repo (`docker-build-push`, `lint-check`, and to a lesser extent `security-scan`) execute code or run scanners against whatever is checked out in the calling job. GitHub Actions has a well-known vulnerability class where a workflow triggered by `pull_request_target` (which runs with the *base* repo's secrets and write permissions) also checks out an *external fork's* PR head — handing that fork's untrusted code the base repo's credentials. See GitHub's own [Preventing pwn requests](https://securitylab.github.com/resources/github-actions-preventing-pwn-requests/) writeup if this is new to you.

**The short version:** if a caller workflow uses `pull_request_target`, do not also check out the PR's head ref in the same job before calling one of these actions. Use plain `pull_request` (runs with a reduced, fork-scoped token and no repo secrets) unless you specifically need `pull_request_target`'s elevated access — and if you do, gate the run behind a required reviewer (a GitHub Environment with required reviewers) instead of letting it run automatically on every fork PR.

Each action's own README has a **Security guardrails** section with specifics for that action — [`lint-check`'s](lint-check/README.md#security-guardrails) is the most important to read, since it's the one action here that installs dependencies and compiles code from the target repo as part of its normal operation, not just as an edge case.

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
| `actions/checkout` *(setup-aws)* | v4.2.2 | `11bd71901bbe5b1630ceea73d27597364c9af683` |
| `aws-actions/configure-aws-credentials` | v6.2.3 | `e6de054238d6b7531b4efff3b6587d9aade6a06c` |
| `aws-actions/amazon-ecr-login` | v2.1.6 | `b040164c4934333d597f3f9c67502ff28f814e9c` |
| `docker/metadata-action` | v6.2.0 | `dc802804100637a589fabce1cb79ff13a1411302` |
| `useblacksmith/setup-docker-builder` | v1.12.0 | `af73aad1881ac50c474addd444fe279cac9be318` |
| `useblacksmith/build-push-action` | v2.3.0 | `9b0579bbec7a6cad2f171596c57e7ac1e7658850` |
| `aquasecurity/trivy-action` | v0.36.0 | `a9c7b0f06e461e9d4b4d1711f154ee024b8d7ab8` |
| `anchore/scan-action` | v6.5.1 | `1638637db639e0ade3258b51db49a9a137574c3e` |
| `actions/upload-artifact` | v4.6.2 | `ea165f8d65b6e75b540449e92b4886f43607fa02` |
| `actions/github-script` | v7.1.0 | `f28e40c7f34bde8b3046d885e986cb6290c5673b` |
| `actions/cache` | v4.3.0 | `0057852bfaa89a56745cba8c7296529d2fc39830` |
| `semgrep/semgrep` *(docker image, digest-pinned)* | 1.173.0 | `sha256:67319956da3dcb58baf5b322899c15458e3963e7018a86aeeb5cd224e69cb77a` |
| `actions/setup-python` | v5.6.0 | `a26af69be951a213d495a4c3e4e4022e16d87065` |
| `actions/setup-node` | v6.5.0 | `249970729cb0ef3589644e2896645e5dc5ba9c38` |
| `dtolnay/rust-toolchain` | v1 (2025-08-23) | `e97e2d8cc328f1b50210efc529dca0028893a2d9` |
| `anchore/sbom-action` | v0.24.0 | `e22c389904149dbc22b58101806040fa8d37a610` |
| `joerick/pr-labels-action` | v1.0.9 | `0543b277721e852d821c6738d449f2f4dea03d5f` |
| `actions/checkout` *(callers)* | v4.4.0 | `11d5960a326750d5838078e36cf38b85af677262` |

`actions/setup-python` and `actions/setup-node` are dependencies introduced by `lint-check` — nothing in the org uses either today, so there's no existing major to match. Pinned to the latest release on the most mature major (v5 / v6) rather than the freshly-cut v6/v7 majors with zero patch releases yet, for the same "won't break" reasoning as matching `ai-engine`'s existing majors elsewhere in this table. `dtolnay/rust-toolchain` doesn't use semver releases — it's the actively maintained, MIT-licensed replacement for the archived `actions-rs/toolchain`, and its own docs recommend pinning `@v1` (a maintained moving tag); pinned here to the commit `v1` currently resolves to, same SHA-pinning rationale as everything else. `lint-check` also installs `ruff`/`yamllint` from PyPI, version-pinned (not SHA-pinned — PyPI has no equivalent); see [`lint-check`'s README](lint-check/README.md#security-guardrails) for the caveat that implies. `anchore/sbom-action` is pre-1.0 (no stable major yet); `ai-engine/tag_bump.yml`'s own inline pin is `v0.20.5`, several minor releases behind — that pin was never audited, not a deliberate version choice, so `sbom-scan` uses the latest release (`v0.24.0`) instead of matching it. `joerick/pr-labels-action` is new — the 3 repos already using it inline are inconsistently pinned to `v1.0.6`/`v1.0.9` on a floating tag (not a SHA); this repo standardizes on `v1.0.9`, SHA-pinned.

**How to update a dependency:**
1. Find the new release tag on the action's GitHub repo
2. Get its SHA: `gh api repos/<owner>/<repo>/git/ref/tags/<tag> --jq '.object.sha'`
3. Replace the SHA and the `# vX.Y.Z` comment in the relevant `action.yml`
4. Open a PR — CI on this repo will validate it before it can be tagged and released

---

## Actions

Each action has its own detailed README covering how it works step by step, full inputs/outputs, and — since this repo is public — an action-specific **Security guardrails** section. Start there before wiring one of these into a workflow; the summaries below are just enough to pick the right action.

### [`setup-aws`](setup-aws/README.md)

Bundles checkout + `configure-aws-credentials` + `amazon-ecr-login` into a single step. Replaces the three-step boilerplate that every workflow needed before any AWS or Docker operation. Requires `id-token: write`.

```yaml
permissions:
  id-token: write
  contents: read

steps:
  - uses: hakimo-ai/actions/setup-aws@v1
    with:
      role-to-assume: ${{ secrets.AWS_ROLE_ARN }}
      aws-region: ${{ vars.AWS_REGION }}
      fetch-depth: '0'   # optional, default is 1
```

---

### [`docker-build-push`](docker-build-push/README.md)

Full ECR auth + Docker metadata + build + push in one step (internally calls `setup-aws`). Replaces the 5-step boilerplate that used to be copy-pasted across every `build-docker-*.yml` in `ai-engine`.

```yaml
permissions:
  id-token: write
  contents: read

steps:
  - uses: actions/checkout@11d5960a326750d5838078e36cf38b85af677262  # v4.4.0

  - id: build
    uses: hakimo-ai/actions/docker-build-push@v1
    with:
      role-to-assume: ${{ secrets.AWS_ROLE_ARN }}
      aws-region: ${{ vars.AWS_REGION }}
      ecr-registry: ${{ secrets.ECR_REGISTRY }}
      ecr-repo: company-vision/alarm-group-etl
      dockerfile: ./Dockerfile.alarmgroups.etl

  - run: echo "Pushed ${{ steps.build.outputs.tags }}"
```

---

### [`security-scan`](security-scan/README.md)

Language-aware security scan — auto-detects Python/Node/Rust/C#/IaC and runs Grype (dependency CVEs), Trivy (secrets + IaC misconfig), and Semgrep (SAST) accordingly. No GitHub Advanced Security dependency: no CodeQL, no SARIF upload. Posts a compact PR comment with the real top findings, centralized so every caller repo gets it for free.

```yaml
permissions:
  contents: read
  pull-requests: write   # required for the PR comment (comment-on-pr, default true)

steps:
  - uses: actions/checkout@11d5960a326750d5838078e36cf38b85af677262  # v4.4.0
    with:
      fetch-depth: 0

  - uses: hakimo-ai/actions/security-scan@v1
    with:
      path: .
      severity-cutoff: 'medium'
```

---

### [`lint-check`](lint-check/README.md)

Language-aware lint/format + deep Python checks — Ruff (Python format + lint), mypy (type checking), pylint (error-mode), ESLint + Prettier (Node, when configured), cargo fmt + clippy (Rust), yamllint. Same PR-comment pattern as `security-scan`. **Unlike `security-scan`, this action executes target-repo code** (`npm ci`, `cargo` compilation, `pip install`) — read its [security guardrails](lint-check/README.md#security-guardrails) before using it on anything that might check out untrusted content.

```yaml
permissions:
  contents: read
  pull-requests: write   # required for the PR comment (comment-on-pr, default true)

steps:
  - uses: actions/checkout@11d5960a326750d5838078e36cf38b85af677262  # v4.4.0

  - uses: hakimo-ai/actions/lint-check@v1
    with:
      path: .
      requirements-file: requirements-base.txt   # optional — needed for mypy/pylint to resolve imports
      pylint-mode: errors-only                    # default; use 'full' for all checks
```

---

### [`sbom-scan`](sbom-scan/README.md)

Generate a real SBOM for a built container image, attach it to a GitHub Release, and scan it for vulnerabilities. Extracted from a working production job in `ai-engine/tag_bump.yml` — not the same thing as `security-scan` (source-scan on every PR, no image/SBOM involved); this one runs at release time against a built image and produces an actual compliance artifact.

```yaml
permissions:
  id-token: write
  contents: write   # only needed if upload-release-assets: 'true'

steps:
  - uses: hakimo-ai/actions/sbom-scan@v1
    with:
      role-to-assume: ${{ secrets.AWS_ROLE_ARN }}
      aws-region: ${{ vars.AWS_REGION }}
      image: ${{ secrets.ECR_REGISTRY }}/company-ai-engine:${{ github.event.release.tag_name }}
      upload-release-assets: 'true'
```

---

### [`pr-label-check`](pr-label-check/README.md)

Fail a job if a PR has no labels. Extracted from a near-identical workflow duplicated in 3 of 4 consumer repos, all pinned to a floating (not SHA-pinned) tag inconsistently — collapses the duplication and fixes the pinning gap in one move.

```yaml
on:
  pull_request:
    types: [opened, synchronize, reopened, edited, labeled, unlabeled]

permissions:
  pull-requests: read

steps:
  - uses: hakimo-ai/actions/pr-label-check@v1
```

---

## Versioning

All actions in this repo share a single version tag (`v1`, `v2`, …). When any action changes, the tag is bumped and callers are updated in a follow-up PR in `ai-engine`.

- Always pin callers to a tag: `uses: hakimo-ai/actions/setup-aws@v1`
- Never use `@main` — a breaking change on main would affect every in-flight run immediately with no warning
- To release a new version: commit to `main`, then `git tag v2 && git push origin v2`
