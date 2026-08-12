# hakimo-ai/actions

Shared composite-action library for Hakimo CI pipelines. All actions are versioned together — pin to a release tag in callers.

```yaml
uses: hakimo-ai/actions/<action-name>@v1
```

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

## Versioning

All actions in this repo share a single version tag (`v1`, `v2`, …). When any action changes, the tag is bumped and callers are updated in a follow-up PR in `ai-engine`.

- Always pin callers to a tag: `uses: hakimo-ai/actions/setup-ecr@v1`
- Never use `@main` — a breaking change on main would affect every in-flight run immediately with no warning
- To release a new version: commit to `main`, then `git tag v2 && git push origin v2`
