# Delivery and identity

## Delivery flow

```mermaid
flowchart LR
  pr[Pull request / push to main] --> validate[validate.yml\naccount-free only]
  dispatch[Manual deploy dispatch\nmain only] --> static[make validate]
  static --> oidc[GitHub OIDC token]
  oidc --> wif[GCP WIF provider\nrepo IDs + exact subject]
  wif --> deployer[assessment-deployer]
  deployer --> foundation[Foundation plan/apply]
  foundation --> platform[Platform plan/apply]
  platform --> workloads[Kustomize workloads + MCI/MCS]
  workloads --> smoke[Smoke + BQ dry runs]
  smoke -. optional .-> hpa[HPA exercise]
  hpa -. optional .-> failover[Application failover exercise]
```

`.github/workflows/validate.yml` has only `contents: read`, never requests an OIDC token, and runs `make tools` plus `make validate`. Deployment and teardown are manual-dispatch-only, reject refs other than `main`, serialize with the non-cancelling `assessment-production` concurrency group, and install Google Cloud CLI 582.0.0 with `gke-gcloud-auth-plugin` and `bq` after federation.

## Identity chain

The bootstrap provider admits only the immutable GitHub repository ID and owner ID plus the exact baseline subject:

```text
repo:OWNER@OWNER_ID/REPO@REPOSITORY_ID:ref:refs/heads/main
```

This repository uses GitHub's immutable default subject format, introduced for repositories created after 2026-07-15. Terraform derives the names and numeric IDs from the validated bootstrap inputs; it also retains separate numeric owner/repository claim checks and the repository-ID `principalSet` binding. A legacy repository or fork can still emit the former name-only subject. Its administrator must opt in to immutable subjects, or deliberately adapt and review the Google trust policy, before bootstrap; copying this policy without matching the active GitHub subject will fail closed.

GitHub's token is exchanged through the GCP Workload Identity Federation provider, then impersonates the single `assessment-deployer` Google service account. No service-account key is created or stored. Repository variables contain only non-secret project, provider, service-account, state-bucket, region, HTTPS, and DNS identifiers.

The one deployer identity is an assessment simplification. It has broad roles needed across foundation, platform, workloads, evidence checks, and teardown, so compromise or workflow misuse has a larger blast radius than a separated production design. A production evolution should split at least:

- bootstrap/state administration, held by a tightly controlled human or separate bootstrap pipeline;
- foundation/network/security deployment;
- platform/cluster/Fleet deployment;
- namespace-scoped workload deployment;
- read-only verification/evidence collection; and
- separately approved teardown.

Each identity should have purpose-built custom roles or the narrowest predefined roles, separate WIF subjects, protected environments, and independent approval paths. Those controls are recommendations; this repository implements exactly one federated deployer.

## Environment-subject hardening caveat

The baseline workflows do not name GitHub Environments, because GitHub replaces the branch suffix when a job references an Environment. For this immutable format the Environment subjects append `:environment:production` or `:environment:teardown` to the active `repo:OWNER@OWNER_ID/REPO@REPOSITORY_ID` prefix. Before adding `environment: production` or `environment: teardown` to any job, update `infra/bootstrap/wif.tf` and the bootstrap state contract to allow only those exact subjects, apply and verify that WIF change, and only then change the workflow jobs. Reversing that order locks the workflows out.

See [ADR 0003](../adr/0003-single-oidc-identity.md), [GitHub hardening](../setup/github.md), and [IAM and secrets](../security/iam-and-secrets.md).
