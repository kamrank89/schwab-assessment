# Prerequisites

## Account-free developer workstation

Use Linux x86-64 with Bash, GNU Make, Git, `curl`, `tar`, `sha256sum`, and standard POSIX utilities. Repository tooling is downloaded into ignored `.tools/bin` at the fixed versions in `tools/versions.env`.

```bash
# Local filesystem/network download only; no cloud account or cloud mutation.
make tools
make tool-versions
make validate
```

`make validate` runs Terraform formatting and `init -backend=false` validation, Kustomize/Kubeconform schema validation, Bash syntax and ShellCheck, actionlint, Grafana JSON parsing, and account-free lifecycle/helper regressions against controlled fake external commands. GKE-specific schemas may be reported as skipped by Kubeconform; recognized Kubernetes schemas must still be valid. The command never authenticates, plans, applies, accesses a cluster, runs Trivy, or proves live behavior.

## GitHub CLI for operator convenience

The setup and lifecycle examples use the supported-current GitHub CLI to set repository variables and dispatch or inspect workflows. Install it using GitHub's [official installation and quickstart guidance](https://docs.github.com/en/github-cli/github-cli/quickstart), then authenticate to the intended GitHub host/account and confirm the session:

```bash
# GITHUB AUTHENTICATION; does not authenticate to Google Cloud.
gh auth login
gh auth status
```

Review the host, account, and token scopes shown by `gh auth status` before any repository administration. The CLI is operator convenience, not a repository validation dependency: `make validate` and pull-request validation do not require `gh` or a GitHub login. GitHub documents the command's supported authentication modes in the [`gh auth login` reference](https://cli.github.com/manual/gh_auth_login).

## Google Cloud CLI 582.0.0

Human bootstrap requires exactly Google Cloud CLI 582.0.0. Authenticated workflow jobs install the same version with `gke-gcloud-auth-plugin` and `bq`. For an isolated Linux x86-64 installation from Google's versioned archive:

```bash
# Local filesystem/network mutation only; review the official archive checksum first.
export ASSESSMENT_GCLOUD_VERSION=582.0.0
curl -fLO "https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/google-cloud-cli-${ASSESSMENT_GCLOUD_VERSION}-linux-x86_64.tar.gz"
tar -xzf "google-cloud-cli-${ASSESSMENT_GCLOUD_VERSION}-linux-x86_64.tar.gz"
./google-cloud-sdk/install.sh --quiet
./google-cloud-sdk/bin/gcloud components install --quiet gke-gcloud-auth-plugin bq
./google-cloud-sdk/bin/gcloud version
./google-cloud-sdk/bin/gke-gcloud-auth-plugin --version
./google-cloud-sdk/bin/bq version
```

Put `google-cloud-sdk/bin` on `PATH` for the operator session. Google's [versioned archive guide](https://cloud.google.com/sdk/docs/downloads-versioned-archives) publishes current archives/checksums; the [GKE access guide](https://cloud.google.com/kubernetes-engine/docs/how-to/cluster-access-for-kubectl) explains why the auth plugin is required.

## Cloud and GitHub inputs

Before bootstrap, obtain:

- an existing GCP project with billing attached; `scripts/bootstrap.sh` deliberately sets `create_project=false`;
- a globally unique GCS bucket name for Terraform state;
- organization-policy approval for GitHub OIDC/WIF and the required APIs, if applicable;
- a human principal able to enable bootstrap APIs, create the state bucket, WIF resources, service account, and IAM bindings;
- GitHub repository name in `OWNER/REPO` form, immutable numeric owner ID, and immutable numeric repository ID;
- GitHub admin access for variables and the recommended branch/environment controls; and
- an owned public DNS name only if HTTPS is required.

Use GitHub's API or repository metadata to verify numeric IDs; do not guess them. Review the broad assessment deployer roles in `infra/bootstrap/locals.tf` before applying. Production should replace these with separated identities and narrower roles.

## Authentication boundary

`gcloud auth application-default login` is for the one-time human bootstrap only. Deployment and teardown use short-lived GitHub OIDC federation. Do not create, download, or upload a service-account key. Never commit `.generated/`, `artifacts/`, `.terraform/`, state, plans, kubeconfigs, tokens, or secret values.

Continue with [bootstrap](bootstrap.md).
