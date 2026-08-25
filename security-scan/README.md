# security-scan

Language-aware security scan: detects what's actually in the target repo and runs the matching open-source scanner, with no GitHub Advanced Security dependency.

## What it does

Auto-detects Python, Node/JS/TS, Rust, C#/.NET, and Dockerfile/Terraform/K8s manifests in the target repo, then runs the scanners that apply — no per-language configuration needed in the caller. Built around fully open-source tooling (Grype, Trivy, Semgrep) because the org does not have a GitHub Advanced Security license — this deliberately avoids CodeQL and never uploads SARIF to the Security tab.

## How it works

| Step | What happens |
|---|---|
| 1. Detect project languages | A `find`-based helper checks the target `path` for Python/Node/Rust/C# manifest files and IaC markers (`Dockerfile`, `*.tf`, `kustomization.y*ml`), and sets a boolean per language plus a combined `sast` flag (true if any of Python/Node/Rust/C# is present). |
| 2. Map severity threshold | Converts the single `severity-cutoff` input into the uppercase, comma-separated list Trivy expects (Grype takes the same value directly). |
| 3. Run Grype | `anchore/scan-action` in path-scan mode — dependency CVEs. Auto-detects Python, npm/yarn, Cargo, and NuGet manifests via Syft's catalogers. Matches the tool already used for image scanning in this org's release workflows, so there's one CVE-scanning tool org-wide instead of introducing a second. |
| 4. Summarize Grype findings | Parses the JSON report into a finding count; if Grype crashed (not "found nothing," an actual tool error), marks the lane as failed instead of reporting a false zero. |
| 5. Run Trivy | `fs` scan with `scanners: secret,misconfig` — secrets and IaC/Dockerfile/K8s misconfig in one pass (vuln scanning is Grype's job, so Trivy's `vuln` scanner is intentionally not enabled). This is what actually covers `deploy`, which is almost entirely Kustomize/K8s YAML. |
| 6. Summarize Trivy findings | Same crash-vs-clean distinction as step 4. |
| 7-9. Semgrep SAST | Only runs if `sast` is true (Python/Node/Rust/C# detected). The Semgrep Docker image is cached (`actions/cache`, keyed on the pinned version) and loaded via `docker load` instead of pulled fresh every run — a cold image pull was the single largest per-run cost outside the scans themselves. Runs `semgrep scan --config <semgrep-config> --json`. On `pull_request` events, when `semgrep-diff-aware: true` (the default), also passes `--baseline-commit <PR base SHA>` so only findings introduced since the PR's base commit are reported, instead of every pre-existing finding in the repo on every PR. Checked on the host (not inside the Semgrep image, which isn't guaranteed to have git) with `git cat-file -e <base SHA>` first — if the base commit isn't available locally (shallow checkout, no `fetch-depth: 0`), falls back to a full scan with a `::warning::` rather than failing outright. No effect on `push`/`schedule` events, which always do a full scan. |
| 10. Summarize Semgrep findings | Same crash-vs-clean distinction, skipped entirely (not just "0 findings") when `sast` was false. |
| 11. Evaluate findings (gate) | Sums all three counts. **Fails the job unconditionally if any scanner crashed**, regardless of `fail-on-findings` — a crash is never allowed to look like a clean scan. Only fails on findings (not crashes) when `fail-on-findings: true`. Independently, `fail-on-secrets: true` fails the job if Trivy's secrets count (tracked separately from its misconfig count) is nonzero — lets a repo make just the secrets lane blocking once it scans clean, without needing `fail-on-findings` to cover Grype/misconfig/Semgrep too. |
| 12. Upload scan reports | The three JSON reports (`grype-results.json`, `trivy-results.json`, `semgrep-results.json`) as a `security-scan-reports` artifact — skipped when there's nothing to show, so a clean run doesn't burn artifact storage. |
| 13. Post PR comment | On `pull_request`/`pull_request_target` only (no-op otherwise). Reads the same three JSON files back off disk, builds a compact per-scanner count table plus the top `max-comment-findings` findings (most severe first) in a collapsed `<details>` block, and upserts a single comment (matched via an HTML marker, paginating through all existing comments so it never misses its own prior comment on an active PR). |

## Inputs

| Input | Required | Default | Description |
|-------|----------|---------|-------------|
| `path` | no | `.` | Root path to scan |
| `severity-cutoff` | no | `high` | Minimum severity to treat as a finding (`negligible`, `low`, `medium`, `high`, `critical`) — drives both Grype's cutoff and Trivy's severity list |
| `semgrep-config` | no | `auto` | Semgrep ruleset config (e.g. `auto`, `p/python`, `p/ci`) |
| `fail-on-findings` | no | `false` | Fail the job if any scanner reports findings (a scanner crash always fails the job regardless of this setting) |
| `fail-on-secrets` | no | `false` | Fail the job if Trivy finds any secrets, independent of `fail-on-findings`. For making just the secrets lane blocking (e.g. once a repo scans clean) while everything else stays monitoring-only |
| `semgrep-diff-aware` | no | `true` | On `pull_request` events, scan only the diff since the PR's base commit instead of the whole repo. Requires enough git history in the caller's checkout to include the base commit (e.g. `fetch-depth: 0`) - falls back to a full scan with a warning otherwise. No effect on `push`/`schedule` events |
| `comment-on-pr` | no | `true` | Post/update a PR comment with the findings summary. No-op outside `pull_request`/`pull_request_target` events |
| `max-comment-findings` | no | `10` | Max number of individual findings (most severe first) to list in the PR comment's collapsed detail section |

## Outputs

| Output | Description |
|--------|--------------|
| `findings-count` | Total number of findings across all scanners |

## Example

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
      severity-cutoff: 'high'
      fail-on-findings: 'false'
```

> Set `comment-on-pr: 'false'` and drop `pull-requests: write` for workflows that only ever run on `push` (no PR to comment on), or that just want the step summary / artifact without a PR comment.

## Known, accepted tradeoffs

- **Secrets scanning only covers the current working tree, not git history.** A key that was committed and later removed will not be caught. Trivy was chosen over a dedicated history-scanning tool (Gitleaks) specifically to keep this pipeline fast — see `CLAUDE.md` for the full reasoning if you have access to it. Revisit if this gap ever causes a real incident.
- **No CodeQL, no SARIF upload to the Security tab.** The org does not have GitHub Advanced Security. Do not add `github/codeql-action` to this action — see the root README's guardrails section for why.

## Security guardrails

- **All three scanners are static analysis — they read files, they don't execute your code.** This makes `security-scan` meaningfully lower-risk than [`lint-check`](../lint-check/README.md), which does execute target-repo code as part of linting. Still pull Grype/Trivy/Semgrep only from the pinned SHA/digest in this repo — don't relax pinning to a floating tag.
- **This action posts PR comments using a token with `pull-requests: write`.** If a caller ever runs this on `pull_request_target` while also checking out an untrusted fork's PR head in the same job, that fork's content could influence what ends up in a comment posted with your repo's credentials. Prefer plain `pull_request` (which runs with the fork's own reduced-permission token and no secrets) unless you specifically need `pull_request_target`'s access to secrets/write permissions — and if you do, don't combine it with checking out fork content.
- **A finding IS a disclosure.** If Trivy's secret scanner finds a live credential, the PR comment and the uploaded artifact both now say so, and both are visible to anyone with read access to the repo/PR — which, once this repo (or the calling repo) is public, may be more people than you expect. Treat "found a secret" as "this secret is now compromised": rotate it immediately, don't just delete the comment or the commit.
- **This action does not modify anything in the target repo.** It only reads files and posts a comment; it has no write access to code, so it cannot itself be a vector for tampering with the repo it scans.
