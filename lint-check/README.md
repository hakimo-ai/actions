# lint-check

Language-aware lint/format check: detects what's actually in the target repo and runs the matching formatter/linter, same detection philosophy as [`security-scan`](../security-scan/README.md).

## What it does

Runs Ruff + mypy + pylint (Python), ESLint + Prettier (Node, only when actually configured), cargo fmt + clippy (Rust), and yamllint against whatever languages are detected — without assuming a single stack across all consumer repos. C#, Go, and C++ are detected but intentionally **not** linted; see "Why C#/Go/C++ are out of scope" below. Optionally also runs `cargo test` for Rust via `run-tests` (off by default).

## How it works

| Step | What happens |
|---|---|
| 1. Detect project languages | Same `find`-based detection pattern as `security-scan`, plus sub-detection for whether ESLint/Prettier are actually configured (a `.eslintrc*`/`eslint.config.*` or `.prettierrc*`/inline `package.json` `"prettier"` key must exist — Node code alone isn't enough to trigger those lanes) and which Node package manager (`npm`/`yarn`/`pnpm`) is in use. |
| 2-3. Ruff | Installs a pinned Ruff version, runs `ruff format --check` and `ruff check --output-format=json`. |
| 4. Install Python deps (optional) | If `requirements-file` is set, runs `pip install -r <file>` before mypy/pylint so they can resolve third-party imports and type stubs. Failures here are soft (`|| true`) — mypy/pylint still run, they'll just report more missing-import noise. |
| 5-6. mypy | Installs a pinned mypy version, runs `mypy ${{ inputs.mypy-args }} --output=json .`. Default args include `--ignore-missing-imports` — safe when not all deps are installed. Exit code 2 = crash (config error), treated as a job failure. Exit code 1 = type errors found, counted as findings. |
| 7-8. pylint | Installs a pinned pylint version. In `errors-only` mode runs `pylint -E` (fast, low false-positive — only real Python errors). In `full` mode runs all checks. Exit codes are a bitmask — bits `1` (fatal) and `32` (usage error) are treated as crashes; all others mean findings were reported. |
| 9-14. ESLint / Prettier | Only run if their config was actually detected. First `actions/setup-node` + a full dependency install (`npm ci`/`yarn install --frozen-lockfile`/`pnpm install --frozen-lockfile`, matching the detected lockfile) — see the guardrails section, this is a real code-execution step, not a formality. Then each tool is smoke-tested (`--version`) before the real run, so "the binary isn't even resolvable" (e.g. a stray `.eslintrc.json` with the tool never added to `package.json`) is distinguished from "the tool ran and found issues." |
| 15-17. cargo fmt + clippy | `dtolnay/rust-toolchain` provisions a toolchain with the `clippy`/`rustfmt` components, then runs `cargo fmt --all --check` and `cargo clippy --all-targets --message-format=json`. Compiling the crate is unavoidable here — clippy needs a real build to analyze — see guardrails. |
| 18-19. cargo test (optional) | Only runs when `run-tests: 'true'`. Runs `cargo test --all-features`. Failed tests are counted as findings (gated by `fail-on-findings`, same as every other lane) — distinguished from a hard compile failure (no `test result:` summary line ever printed), which is always treated as a crash regardless of `fail-on-findings`, same convention as the clippy JSON-stream check above. |
| 20-21. yamllint | Installs a pinned yamllint version, runs `yamllint -f parsable`. Same tool/config philosophy as this repo's own `.yamllint.yml`. |
| 22. Evaluate findings (gate) | Sums every lane's count. **Fails the job unconditionally if any lane crashed**, regardless of `fail-on-findings`. Because most of these tools don't have a Grype/Trivy-style "don't fail the build" flag, this gate instead relies on each run step catching the tool's exit code directly and applying the shared Unix-linter convention (`0`=clean, `1`=findings, anything else=crash) — including catching the case where a setup step itself (`Setup Node`, `Setup Rust toolchain`) failed and cascaded to skip everything downstream, which is treated the same as a crash, not silently reported as "0 findings." |
| 23. Upload lint reports | Per-tool result files as a `lint-check-reports` artifact, skipped when there's nothing to show. |
| 24. Post PR comment | Same compact-table + collapsed-`<details>` pattern as `security-scan`. Shows Ruff, mypy, and pylint rows for Python repos. Also calls out C#/Go/C++ by name when detected ("detected but not linted by this action"), and does the same for a Node repo that has `package.json` but no ESLint/Prettier config, so a real coverage gap is visible instead of looking identical to "no Node code here." The comment marker includes `path`, so calling this action more than once in the same PR (e.g. a matrix over several crates/packages) gives each call its own comment instead of racing to overwrite one shared marker - the visible heading also shows the path, except for the default `.` case, which keeps its plain unlabeled heading. |

## Why C#/Go/C++ are out of scope

- **C#**: C# code in consumer repos typically builds via proprietary SDK installers on self-hosted **Windows** runners. There's no way for a generic Linux composite action to restore or analyze it.
- **Go**/**C++**: both typically have dedicated per-repo tooling (`dominikh/staticcheck-action`, `clang-format`) and represent a handful of files each — not worth centralizing.

When detected, all three are named explicitly in the PR comment rather than silently ignored, so the gap is visible instead of assumed-covered.

## Inputs

| Input | Required | Default | Description |
|-------|----------|---------|-------------|
| `path` | no | `.` | Root path to lint |
| `python-version` | no | `3.12` | Python version for Ruff, mypy, and pylint |
| `node-version` | no | `20` | Node version for ESLint/Prettier |
| `rust-toolchain` | no | `stable` | Rust toolchain channel for cargo fmt/clippy/test |
| `run-tests` | no | `false` | Also run `cargo test --all-features` when Rust is detected. Off by default so existing callers are unaffected. Test failures count as findings, gated by `fail-on-findings` like every other lane |
| `fail-on-findings` | no | `false` | Fail the job if any linter reports findings (a linter crash always fails the job regardless of this setting) |
| `comment-on-pr` | no | `true` | Post/update a PR comment with the findings summary. No-op outside `pull_request`/`pull_request_target` events |
| `max-comment-findings` | no | `10` | Max number of individual findings (most severe first) to list in the PR comment's collapsed detail section |
| `requirements-file` | no | `''` | Path to a requirements file (relative to `path`) to install before running mypy and pylint. Leave empty to skip dependency install — mypy/pylint still run but will report more missing-import noise without the project's deps available. |
| `mypy-args` | no | `--ignore-missing-imports` | Extra args to pass to mypy. The default is safe when not all deps are installed. |
| `pylint-mode` | no | `errors-only` | `errors-only` runs `pylint -E` (fast, catches real errors, low false-positive rate). `full` runs all checks including style and convention warnings. |

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
      requirements-file: requirements-base.txt   # omit if you don't need mypy/pylint import resolution
      pylint-mode: errors-only                    # default; 'full' for all checks
```

## Security guardrails

**Unlike `security-scan`, this action executes code from the target repo — this is by design, not an oversight, and it's the single most important thing to understand before wiring this into a workflow.**

- **`npm ci`/`yarn install`/`pnpm install` run the full dependency tree's install scripts.** `postinstall`/`preinstall` hooks executing arbitrary code from a transitive dependency is one of the most common real-world supply-chain attack vectors in the npm ecosystem. This isn't specific to this action — it's true of any workflow that installs npm dependencies — but it means the ESLint/Prettier lane is a genuine code-execution surface, not just a linter.
- **`cargo clippy`/`cargo fmt --check` require compiling the crate.** Rust's `build.rs` build scripts and procedural macros both run arbitrary code at compile time by design — this is normal Rust tooling behavior, not a bug, but it means the Rust lane is also a code-execution surface. **`cargo test` (when `run-tests: 'true'`) goes further and actually executes the compiled test binaries** — a bigger surface than fmt/clippy's compile-only step, same category of risk as installing and running any other test suite.
- **`pip install -r requirements-file` (when set) installs the project's own deps.** mypy and pylint import the target repo's code to analyze it — that's what makes them accurate. When `requirements-file` is set, those deps are installed first. A compromised transitive dependency in `requirements-base.txt` runs code at install time here, same as anywhere else pip is used.
- **Never combine this action with checking out untrusted fork PR content in a `pull_request_target` workflow.** That combination hands the runner's full permissions and any job secrets to code you don't control, the moment `npm ci`, `cargo clippy`, or `pip install` runs. Use plain `pull_request` instead (runs with the fork's own reduced token and no secrets) unless you specifically need `pull_request_target`, and never check out a fork's PR head in that case. See the [pwn request](https://securitylab.github.com/resources/github-actions-preventing-pwn-requests/) writeup linked from `setup-aws`'s README for the general pattern this avoids.
- **Ruff, ESLint, Prettier, yamllint, mypy, pylint, and clippy's actual lint output are comparatively low-risk on their own** — they're static analyzers. The install/compile steps that precede them are the real risk surface, not the linting itself.
- **`pip install ruff==<pinned>` / `pip install yamllint==<pinned>` / `pip install mypy==<pinned>` / `pip install pylint==<pinned>` pull from PyPI at run time, version-pinned but not SHA-pinned** — PyPI (like npm/crates.io) has no commit-SHA equivalent to pin against, so this is a slightly weaker guarantee than the GitHub Actions in this repo, which are all pinned to a full commit SHA. A compromised release of an already-pinned version is rare but not the same immutability guarantee. Same caveat applies to whatever version of npm/cargo/node the target repo's own toolchain resolves to during install/build.
