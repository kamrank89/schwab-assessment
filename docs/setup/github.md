# GitHub configuration and governance

## Repository variables

`scripts/configure-github-variables.sh` sets exactly these 13 non-secret repository variables:

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

## Permanent cluster administrator

Bootstrap configures the 13 generated/fixed variables above. It cannot know which human should receive the separate, permanent super-user grant, so a repository administrator must add this required 14th variable locally after bootstrap:

```bash
read -rp 'Cluster administrator Google email: ' GCP_CLUSTER_ADMIN_EMAIL
gh variable set GCP_CLUSTER_ADMIN_EMAIL \
  --repo kamrank89/schwab-assessment \
  --body "${GCP_CLUSTER_ADMIN_EMAIL}"
unset GCP_CLUSTER_ADMIN_EMAIL
```

This value is an identity, not a password, but it grants a permanent administrator path: Connect Gateway Reader/Admin, exact-user Kubernetes `cluster-admin` in both clusters, and access to the Grafana password secret. Treat it as a reviewed super-user assignment. Changing this variable does not itself change cloud access; run a reviewed Deploy afterward so Terraform and Kubernetes reconcile the successor identity. Follow the [revocation lifecycle](../security/iam-and-secrets.md#permanent-operator-and-revocation) when removing or replacing an operator.

`deploy.yml` also has three dispatch-time booleans, all default-disabled: `https_to_http_transition`, `run_hpa_drill`, and `run_failover_drill`. The transition input is only the first half of an HTTPS-to-HTTP change, skips foundation/platform Terraform mutation, and rejects either drill; follow [DNS/TLS](dns-tls.md) before selecting it.

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

## Immutable WIF subject and Environment migration

This repository uses GitHub's immutable default subject format for repositories created after 2026-07-15. The public repository OIDC metadata reports an immutable prefix, and bootstrap derives the active names and numeric IDs from its validated inputs. Every baseline privileged job must therefore present exactly:

```text
repo:OWNER@OWNER_ID/REPO@REPOSITORY_ID:ref:refs/heads/main
```

Terraform also checks the numeric `repository_id` and `repository_owner_id` claims separately and binds service-account impersonation through a repository-ID `principalSet`. Repositories created before the cutoff, GitHub Enterprise Server repositories, and some forks can have a different active subject. Before bootstrap, a repository administrator must either opt a legacy github.com repository into immutable subjects or deliberately adapt and review the trust policy to match its previewed subject. Do not assume that names, IDs, or a copied trust policy match.

When a job references a GitHub Environment, GitHub replaces the branch suffix with an Environment suffix. With the active immutable prefix, the two proposed subjects are `repo:OWNER@OWNER_ID/REPO@REPOSITORY_ID:environment:production` and `repo:OWNER@OWNER_ID/REPO@REPOSITORY_ID:environment:teardown`. The current Terraform provider condition rejects both. The safe order is:

1. Preview and review the exact active `production` and `teardown` subjects using GitHub's [OIDC subject reference](https://docs.github.com/en/actions/reference/security/oidc) and [OIDC REST API](https://docs.github.com/en/rest/actions/oidc).
2. Modify `infra/bootstrap/wif.tf` and bootstrap recovery validation to allow only those exact subjects plus immutable repository/owner IDs.
3. **Cloud IAM mutation:** apply the reviewed bootstrap change using the existing state, and verify federation.
4. Add `environment: production` and `environment: teardown` to the relevant workflow jobs.
5. Enable Environment reviewers, prevent-self-review, and deployment-branch restrictions.

Do not add Environments to the jobs first: that changes the token subject before Google trusts it and causes authentication failure. Long term, use separate WIF providers/identities rather than widening one allowlist indefinitely.
