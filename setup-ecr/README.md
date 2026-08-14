# setup-ecr

Configures AWS credentials via OIDC and logs Docker in to Amazon ECR, in one step.

## What it does

Every workflow that needs to push or pull a Docker image from ECR needs two things first: an authenticated AWS session, and a `docker login` against the ECR registry. This action wraps both into a single `uses:` line instead of repeating the same two steps in every caller workflow.

## How it works

| Step | Action | What happens |
|---|---|---|
| 1. Configure AWS credentials | `aws-actions/configure-aws-credentials` | Exchanges the job's OIDC token for temporary AWS credentials by assuming `role-to-assume` in `aws-region`. No long-lived AWS access keys are ever stored in this repo or the caller — this is why the caller's job needs `permissions: id-token: write`. |
| 2. Login to Amazon ECR | `aws-actions/amazon-ecr-login` | Uses the credentials from step 1 to get an ECR authorization token and `docker login`s the runner against the registry. |

After this action runs, every subsequent step in the job has an authenticated `docker` CLI and valid AWS credentials in the environment (see guardrails below).

## Inputs

| Input | Required | Description |
|-------|----------|-------------|
| `role-to-assume` | yes | IAM role ARN to assume via OIDC |
| `aws-region` | yes | AWS region (e.g. `us-west-2`) |

## Outputs

None. Downstream steps use the AWS credentials and Docker login implicitly (via the environment/Docker config), not via an action output.

## Example

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

> Requires `id-token: write` so the OIDC token can be exchanged for AWS credentials. Never hardcode `role-to-assume` — pass it via a repo/org secret or variable, exactly like the example above.

## Security guardrails

This action grants an authenticated AWS session (and a Docker login) to **every step that runs after it in the same job**, including any step added later in the workflow file — this action has no way to scope that down.

- **Don't run untrusted code after this step in the same job.** If a later step in the job checks out or executes code from an untrusted source (e.g. a fork PR's contents on `pull_request_target`), that code runs with the AWS session this action just created. This is the general "pwn request" pattern GitHub Actions is prone to — see [GitHub's own writeup](https://securitylab.github.com/resources/github-actions-preventing-pwn-requests/) if you're not familiar. Concretely: never combine this action with a `checkout` of an external fork's PR head in the same job unless a human has approved the run first (a GitHub Environment with required reviewers is the standard mitigation).
- **Scope `role-to-assume` narrowly.** This action does not restrict what the assumed role can do — that's entirely down to the IAM role's own trust policy and permissions. A role that's only ever used to push to one ECR repo should not also have broader account access "just in case."
- **Don't add debug/verbose logging steps after this action.** `configure-aws-credentials` masks the credential values in the Actions log by default, but a step that dumps the full environment (`env`, `printenv`, a misconfigured debug flag) can still leak them into logs — which, in this public repo's callers, may be more visible than you expect.
