# GitHub configuration and governance

## Repository variables

`scripts/configure-github-variables.sh` sets exactly these non-secret repository variables:

| Variable | HTTP baseline |
| --- | --- |
| `GCP_PROJECT_ID` | bootstrap output |
| `GCP_PROJECT_NUMBER` | bootstrap output |
| `GCP_WIF_PROVIDER` | bootstrap output |
| `GCP_DEPLOYER_SERVICE_ACCOUNT` | bootstrap output |
| `TF_STATE_BUCKET` | bootstrap output |
| `GCP_REGION_PRIMARY` | `us-central1` |
| `GCP_REGION_SECONDARY` | `us-east1` |
| `GCP_ENABLE_HTTPS` | `false` |
| `GCP_MANAGE_DNS` | `false` |
| `GCP_CREATE_DNS_ZONE` | `false` |
| `GCP_DNS_NAME` | empty |
| `GCP_DNS_ZONE_NAME` | empty |
| `GCP_DNS_ZONE_DNS_NAME` | empty |

These are identifiers and feature flags, not credentials. Never replace WIF with a JSON service-account key or a GitHub cloud-key secret.

## Recommended production governance checklist

These controls are manual recommendations, not prerequisites automated by this repository and not claims about the current repository settings.

- Protect `main`; require pull requests, approvals, resolved conversations, and the `validate` status check before merge.
- Restrict direct pushes and force pushes, including administrator bypass where the organization's policy permits.
- Add `.github/CODEOWNERS` covering Terraform, Kubernetes, workflows, lifecycle scripts, and the CODEOWNERS file itself; enable required Code Owner review.
- Create protected `production` and `teardown` Environments with required reviewers, prevent self-review, disable administrator bypass if available, and restrict deployment branches/tags to `main`.
- Use a different reviewer group for teardown, and require a linked change/ticket and evidence plan.
- Restrict who can dispatch deployment workflows and who can modify repository variables.
- Keep action pins reviewable through Dependabot; do not auto-merge workflow dependency updates.

GitHub documents [required checks and branch protection](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-protected-branches/about-protected-branches), [CODEOWNERS](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/customizing-your-repository/about-code-owners), and [Environment reviewers and branch restrictions](https://docs.github.com/en/actions/reference/workflows-and-actions/deployments-and-environments).

## WIF subject migration before Environments

Today every privileged job has a branch-based OIDC subject:

```text
repo:OWNER/REPO:ref:refs/heads/main
```

When a job references a GitHub Environment, GitHub changes the subject to include the Environment. The current Terraform provider condition will reject it. The safe order is:

1. Determine and review the exact `production` and `teardown` subjects from GitHub's [OIDC subject reference](https://docs.github.com/en/actions/reference/security/oidc).
2. Modify `infra/bootstrap/wif.tf` and bootstrap recovery validation to allow only those exact subjects plus immutable repository/owner IDs.
3. **Cloud IAM mutation:** apply the reviewed bootstrap change using the existing state, and verify federation.
4. Add `environment: production` and `environment: teardown` to the relevant workflow jobs.
5. Enable Environment reviewers, prevent-self-review, and deployment-branch restrictions.

Do not add Environments to the jobs first: that changes the token subject before Google trusts it and causes authentication failure. Long term, use separate WIF providers/identities rather than widening one allowlist indefinitely.
