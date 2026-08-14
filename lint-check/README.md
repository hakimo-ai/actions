# lint-check

Language-aware lint/format check: detects what's actually in the target repo and runs the matching formatter/linter, same detection philosophy as [`security-scan`](../security-scan/README.md).

## What it does

Runs Ruff (Python), ESLint + Prettier (Node, only when actually configured), cargo fmt + clippy (Rust), and yamllint against whatever languages are detected — instead of assuming one stack across `ai-engine`, `vision`, `hakimo-ui`, and `deploy`. C#, Go, and C++ are detected but intentionally **not** linted; see "Why C#/Go/C++ are out of scope" below.

## How it works

| Step | What happens |
|---|---|
| 1. Detect project languages | Same `find`-based detection pattern as `security-scan`, plus sub-detection for whether ESLint/Prettier are actually configured (a `.eslintrc*`/`eslint.config.*` or `.prettierrc*`/inline `package.json` `"prettier"` key must exist — Node code alone isn't enough to trigger those lanes) and which Node package manager (`npm`/`yarn`/`pnpm`) is in use. |
| 2-3. Ruff | Installs a pinned Ruff version, runs `ruff format --check` and `ruff check --output-format=json`. Deliberately excludes mypy and pylint — see below. |
| 4-9. ESLint / Prettier | Only run if their config was actually detected. First `actions/setup-node` + a full dependency install (`npm ci`/`yarn install --frozen-lockfile`/`pnpm install --frozen-lockfile`, matching the detected lockfile) — see the guardrails section, this is a real code-execution step, not a formality. Then each tool is smoke-tested (`--version`) before the real run, so "the binary isn't even resolvable" (e.g. a stray `.eslintrc.json` with the tool never added to `package.json`) is distinguished from "the tool ran and found issues." |
| 10-12. cargo fmt + clippy | `dtolnay/rust-toolchain` provisions a toolchain with the `clippy`/`rustfmt` components, then runs `cargo fmt --all --check` and `cargo clippy --all-targets --message-format=json`. Compiling the crate is unavoidable here — clippy needs a real build to analyze — see guardrails. |
| 13-14. yamllint | Installs a pinned yamllint version, runs `yamllint -f parsable`. Same tool/config philosophy as this repo's own `.yamllint.yml`. |
| 15. Evaluate findings (gate) | Sums every lane's count. **Fails the job unconditionally if any lane crashed**, regardless of `fail-on-findings`. Because most of these tools don't have a Grype/Trivy-style "don't fail the build" flag, this gate instead relies on each run step catching the tool's exit code directly and applying the shared Unix-linter convention (`0`=clean, `1`=findings, anything else=crash) — including catching the case where a setup step itself (`Setup Node`, `Setup Rust toolchain`) failed and cascaded to skip everything downstream, which is treated the same as a crash, not silently reported as "0 findings." |
| 16. Upload lint reports | Per-tool result files as a `lint-check-reports` artifact, skipped when there's nothing to show. |
| 17. Post PR comment | Same compact-table + collapsed-`<details>` pattern as `security-scan`. Also calls out C#/Go/C++ by name when detected ("detected but not linted by this action"), and does the same for a Node repo that has `package.json` but no ESLint/Prettier config, so a real coverage gap is visible instead of looking identical to "no Node code here." |

## Why mypy/pylint aren't included

mypy's flags already diverge between `ai-engine` and `vision` in their real CI (different `--ignore-missing-imports`/module lists), so a one-size-fits-all invocation here would either be wrong for one of them or need per-caller config that defeats the point of a shared action. pylint's score-baseline gate in `ai-engine` is a different kind of thing entirely — a ratcheting quality gate, not a stateless lint pass — and is the separate, not-yet-built `quality-gate-check` action. Keeping `lint-check` to fast, stateless format/lint checks keeps its job boundary clean.

## Why C#/Go/C++ are out of scope

- **C#**: the only C# code (`ai-engine/integ/{genetec,velocity,milestone}`) builds via proprietary SDK installers on a self-hosted **Windows** runner (`cs-build.yml`). There's no way for a generic Linux composite action to restore or analyze it.
- **Go**/**C++**: both already have dedicated per-repo tooling (`dominikh/staticcheck-action` in `go-build.yml`, `clang-format` in `cpp_workflow.yml`) and represent a handful of files each — not worth centralizing.

When detected, all three are named explicitly in the PR comment rather than silently ignored, so the gap is visible instead of assumed-covered.

## Inputs

| Input | Required | Default | Description |
|-------|----------|---------|-------------|
| `path` | no | `.` | Root path to lint |
| `python-version` | no | `3.12` | Python version for Ruff |
| `node-version` | no | `20` | Node version for ESLint/Prettier |
| `rust-toolchain` | no | `stable` | Rust toolchain channel for cargo fmt/clippy |
| `fail-on-findings` | no | `false` | Fail the job if any linter reports findings (a linter crash always fails the job regardless of this setting) |
| `comment-on-pr` | no | `true` | Post/update a PR comment with the findings summary. No-op outside `pull_request`/`pull_request_target` events |
| `max-comment-findings` | no | `10` | Max number of individual findings (most severe first) to list in the PR comment's collapsed detail section |

## Outputs

| Output | Description |
|--------|--------------|
| `findings-count` | Total number of findings across all linters |

## Example

```yaml
permissions:
  contents: read
  pull-requests: write   # required for the PR comment (comment-on-pr, default true)

steps:
  - uses: actions/checkout@11d5960a326750d5838078e36cf38b85af677262  # v4.4.0

  - uses: hakimo-ai/actions/lint-check@v1
    with:
      path: .
      fail-on-findings: 'false'
```

## Security guardrails

**Unlike `security-scan`, this action executes code from the target repo — this is by design, not an oversight, and it's the single most important thing to understand before wiring this into a workflow.**

- **`npm ci`/`yarn install`/`pnpm install` run the full dependency tree's install scripts.** `postinstall`/`preinstall` hooks executing arbitrary code from a transitive dependency is one of the most common real-world supply-chain attack vectors in the npm ecosystem. This isn't specific to this action — it's true of any workflow that installs npm dependencies — but it means the ESLint/Prettier lane is a genuine code-execution surface, not just a linter.
- **`cargo clippy`/`cargo fmt --check` require compiling the crate.** Rust's `build.rs` build scripts and procedural macros both run arbitrary code at compile time by design — this is normal Rust tooling behavior, not a bug, but it means the Rust lane is also a code-execution surface.
- **Never combine this action with checking out untrusted fork PR content in a `pull_request_target` workflow.** That combination hands the runner's full permissions and any job secrets to code you don't control, the moment `npm ci` or `cargo clippy` runs. Use plain `pull_request` instead (runs with the fork's own reduced token and no secrets) unless you specifically need `pull_request_target`, and never check out a fork's PR head in that case. See the [pwn request](https://securitylab.github.com/resources/github-actions-preventing-pwn-requests/) writeup linked from `setup-ecr`'s README for the general pattern this avoids.
- **Ruff, ESLint, Prettier, yamllint, and clippy's actual lint output are comparatively low-risk on their own** — they're static analyzers. The install/compile steps that precede them are the real risk surface, not the linting itself.
- **`pip install ruff==<pinned>` / `pip install yamllint==<pinned>` pull from PyPI at run time, version-pinned but not SHA-pinned** — PyPI (like npm/crates.io) has no commit-SHA equivalent to pin against, so this is a slightly weaker guarantee than the GitHub Actions in this repo, which are all pinned to a full commit SHA. A compromised release of an already-pinned version is rare but not the same immutability guarantee. Same caveat applies to whatever version of npm/cargo/node the target repo's own toolchain resolves to during install/build.
