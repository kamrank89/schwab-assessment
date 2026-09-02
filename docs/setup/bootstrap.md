# One-time human bootstrap

Bootstrap attaches to an existing project, enables the bootstrap APIs, creates a versioned GCS state bucket, creates the repository-scoped GitHub WIF pool/provider, creates `assessment-deployer`, and grants its assessment roles. It is intentionally refused when `GITHUB_ACTIONS=true`.

## Run

1. Confirm Google Cloud CLI 582.0.0, Terraform, and `jq` are on `PATH`.
2. Authenticate a human with Application Default Credentials:

   ```bash
   # Human authentication; does not itself deploy assessment resources.
   gcloud auth application-default login
   ```

3. Bootstrap from a clean `main` checkout:

   ```bash
   # CLOUD MUTATION and potential cost: APIs, state bucket, WIF, service account, IAM.
   make bootstrap \
     PROJECT_ID=example-project \
     STATE_BUCKET=example-project-tfstate \
     GITHUB_REPOSITORY=OWNER/REPO \
     GITHUB_OWNER_ID=123 \
     GITHUB_REPOSITORY_ID=456
   ```

4. Read the prompt and type the exact project ID. The script will not accept a generic yes.

The script first inventories local `infra/bootstrap/terraform.tfstate` and remote `gs://STATE_BUCKET/bootstrap/default.tfstate`. It fails closed on unreadable, conflicting, unexpected, non-default-workspace, errored, or partial state. A first local apply is migrated into the versioned bucket and compared before the local copy is removed. Safe reruns select an existing valid remote state rather than creating a second identity boundary.

## Outputs and GitHub variables

Five non-secret Terraform outputs are written to ignored `.generated/bootstrap-outputs.json` with mode 0600:

```text
GCP_PROJECT_ID
GCP_PROJECT_NUMBER
GCP_WIF_PROVIDER
GCP_DEPLOYER_SERVICE_ACCOUNT
TF_STATE_BUCKET
```

If `gh auth status` succeeds, bootstrap invokes `configure-github-variables.sh` and also sets fixed regions, HTTP-first booleans, and empty DNS values. Otherwise run:

```bash
# GITHUB REPOSITORY MUTATION, non-secret variables only.
make configure-github-variables \
  GITHUB_REPOSITORY=OWNER/REPO \
  OUTPUTS_FILE=.generated/bootstrap-outputs.json
```

The helper never creates a GitHub secret, Environment, reviewer, or branch rule. Apply the [GitHub governance checklist](github.md) separately.

## No-key and state policy

- The WIF condition checks immutable repository and owner IDs and the exact `main` branch subject.
- No service-account key operation exists. The bootstrap output file contains identifiers, not credentials.
- The state bucket enforces public-access prevention and uniform bucket-level access, enables object versioning, and keeps up to ten newer noncurrent versions through a lifecycle rule.
- Do not print, upload, or hand-edit state. If bootstrap reports conflicting or errored state, stop and perform explicit state recovery; do not delete the file or bucket to bypass the guard.
- Bootstrap is not destroyed by normal teardown. Its retained state is the anchor for a later redeploy.

Bootstrap runtime and cloud behavior are `deployment-evidence-pending` until an authorized operator records them.
