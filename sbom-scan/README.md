# sbom-scan

Generate a real, downloadable SBOM for a built container image, attach it to a GitHub Release, and scan it for vulnerabilities.

## What it does

Extracted from a working production job in `ai-engine/tag_bump.yml` (matrix over 3 images) — not a new design, a reusable version of existing logic, same story as [`docker-build-push`](../docker-build-push/README.md) extracting `ai-engine`'s 15 `build-docker-*.yml` files.

**This is not the same thing as [`security-scan`](../security-scan/README.md), even though both use Grype.** `security-scan` runs in path-scan mode against the checked-out repo's dependency manifests, on every PR — no image, no SBOM artifact, just a PR comment. `sbom-scan` runs in image-scan mode: it pulls a *built and pushed* container image, generates an actual SPDX/CycloneDX SBOM document (a real compliance/audit deliverable — "here's exactly what's in this released image"), uploads it as a workflow artifact and, optionally, a GitHub Release asset, and only then scans that SBOM. Different trigger point (release time, not PR time), different output, genuinely new capability `security-scan` doesn't provide. The overlap in CVE-finding between the two is a feature (defense in depth — catch it again at release in case something changed since merge), not a bug.

## How it works

| Step | What happens |
|---|---|
| 1. Setup ECR | Calls [`hakimo-ai/actions/setup-aws@v1`](../setup-aws/README.md) internally — needed because `anchore/sbom-action` has to pull `image` from the registry to inspect it. |
| 2. Compute SBOM file name | Validates `format` (only `spdx-json`/`cyclonedx-json` are supported — anything else fails loudly here instead of silently mislabeling the output file's extension later). Derives a filesystem/artifact-safe base name from either `sbom-name` (if given) or a sanitized version of `image`, then emits the real absolute path once — every later step and the action's own `sbom-path` output use that same value directly, nothing re-derives it. |
| 3. Generate SBOM | `anchore/sbom-action` produces the SBOM file, uploads it as a workflow artifact, and (if `upload-release-assets: 'true'`) attaches it to the current GitHub Release. |
| 4. Scan SBOM | `anchore/scan-action` (the same tool `security-scan` uses for Grype, in the mode that scans an existing SBOM document instead of a live path) — `output-format: json` so findings are machine-parseable, `fail-build: 'false'` so a dirty scan doesn't itself crash the step. |
| 5. Evaluate findings (gate) | Checks all four prior steps' outcomes individually (`setup-aws`/`name`/`sbom`/`scan`) and fails the job with a specific, accurate error naming which one broke if any of them didn't succeed — **regardless of `fail-on-findings`**. Only fails on findings (not crashes) when `fail-on-findings: true` and the scan actually found something at or above `severity-cutoff`. |

This is a single-image action — for a matrix of images (like `ai-engine`'s 3), the caller keeps its own `strategy: matrix` at the job level and calls `sbom-scan` once per matrix entry, the same way a caller would call `docker-build-push` once per Dockerfile.

## Inputs

| Input | Required | Default | Description |
|-------|----------|---------|-------------|
| `role-to-assume` | yes | — | IAM role ARN to assume via OIDC |
| `aws-region` | yes | — | AWS region |
| `image` | yes | — | Full image reference to generate an SBOM for |
| `sbom-name` | no | `''` | Base name for the SBOM file/artifact. Defaults to a sanitized version of `image` |
| `format` | no | `spdx-json` | SBOM format — `spdx-json` or `cyclonedx-json` only |
| `severity-cutoff` | no | `medium` | Minimum severity to treat as a finding |
| `fail-on-findings` | no | `false` | Fail the job if the scan reports findings (a crash always fails the job regardless) |
| `upload-release-assets` | no | `false` | Attach the SBOM to the current GitHub Release. Only meaningful on a `release` event — requires `contents: write` on the caller's job |

## Outputs

| Output | Description |
|--------|--------------|
| `sbom-path` | Absolute path to the generated SBOM file |
| `findings-count` | Number of vulnerability findings in the SBOM scan |

## Example

```yaml
permissions:
  id-token: write
  contents: write   # only needed if upload-release-assets: 'true'

on:
  release:
    types: [released]

jobs:
  sbom:
    strategy:
      matrix:
        image: [company-ai-engine, company-ml-service, company-hip]
    steps:
      - uses: hakimo-ai/actions/sbom-scan@v1
        with:
          role-to-assume: ${{ secrets.AWS_ROLE_ARN }}
          aws-region: ${{ vars.AWS_REGION }}
          image: ${{ secrets.ECR_REGISTRY }}/${{ matrix.image }}:${{ github.event.release.tag_name }}
          upload-release-assets: 'true'
```

## Security guardrails

- **Static analysis only — this action doesn't execute the image's contents.** `anchore/sbom-action`/`anchore/scan-action` inspect image layers and manifests; they don't run the image. Meaningfully lower-risk than [`lint-check`](../lint-check/README.md), similar profile to [`security-scan`](../security-scan/README.md).
- **This action authenticates to AWS and pulls a real image**, same guardrail as `setup-aws`: everything downstream in the same job has access to the AWS session it creates. Don't run untrusted code in the same job after this step.
- **An SBOM is a disclosure by design — that's its whole purpose**, but it's a broader one than `security-scan`'s PR comment: an SBOM lists every dependency and version in the shipped image, not just the ones with findings. If `upload-release-assets: 'true'`, that document becomes a public Release asset (on a public repo) or is visible to anyone with release-read access (on a private one) — make sure that's the intended audience before enabling it, independent of whether any vulnerabilities were found.
- **`sbom-name`, if you set it explicitly, is still sanitized** (stripped to `[A-Za-z0-9._-]`) before being used as both a GitHub artifact name and a file path — but don't rely on that as an input-validation boundary for anything beyond this action's own file-naming needs.
