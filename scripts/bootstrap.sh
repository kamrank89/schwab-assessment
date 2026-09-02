#!/usr/bin/env bash
set -euo pipefail

umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd -P)"
BOOTSTRAP_ROOT="${REPO_ROOT}/infra/bootstrap"
OUTPUT_DIR="${REPO_ROOT}/.generated"
OUTPUT_FILE="${OUTPUT_DIR}/bootstrap-outputs.json"
BACKEND_FILE="${BOOTSTRAP_ROOT}/backend.generated.tf"

usage() {
  cat <<'USAGE'
Usage: bootstrap.sh --project-id ID --state-bucket BUCKET \
  --github-repository OWNER/REPO --github-owner-id ID \
  --github-repository-id ID

This is a one-time, human-credential bootstrap. It cannot run in GitHub Actions.
USAGE
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

require_value() {
  [[ -n "${2-}" ]] || die "$1 requires a non-empty value."
}

PROJECT_ID=""
STATE_BUCKET=""
GITHUB_REPOSITORY=""
GITHUB_OWNER_ID=""
GITHUB_REPOSITORY_ID=""

while (($# > 0)); do
  case "$1" in
    --project-id)
      require_value "$1" "${2-}"
      PROJECT_ID="$2"
      shift 2
      ;;
    --state-bucket)
      require_value "$1" "${2-}"
      STATE_BUCKET="$2"
      shift 2
      ;;
    --github-repository)
      require_value "$1" "${2-}"
      GITHUB_REPOSITORY="$2"
      shift 2
      ;;
    --github-owner-id)
      require_value "$1" "${2-}"
      GITHUB_OWNER_ID="$2"
      shift 2
      ;;
    --github-repository-id)
      require_value "$1" "${2-}"
      GITHUB_REPOSITORY_ID="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      die "Unknown argument: $1"
      ;;
  esac
done

[[ "${GITHUB_ACTIONS:-false}" != "true" ]] ||
  die "bootstrap.sh is human-only and refuses to run in GitHub Actions."
[[ "${PROJECT_ID}" =~ ^[a-z][a-z0-9-]{4,28}[a-z0-9]$ ]] || die "Invalid Google Cloud project ID."
[[ "${STATE_BUCKET}" =~ ^[a-z0-9][a-z0-9._-]{1,61}[a-z0-9]$ ]] || die "Invalid GCS bucket name."
[[ "${GITHUB_REPOSITORY}" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,37}[A-Za-z0-9])?/[A-Za-z0-9._-]{1,100}$ ]] ||
  die "GitHub repository must have the form OWNER/REPO."
[[ "${GITHUB_OWNER_ID}" =~ ^[1-9][0-9]*$ ]] || die "GitHub owner ID must contain only digits."
[[ "${GITHUB_REPOSITORY_ID}" =~ ^[1-9][0-9]*$ ]] || die "GitHub repository ID must contain only digits."
[[ -d "${BOOTSTRAP_ROOT}" ]] || die "Bootstrap Terraform root is missing."

for command_name in gcloud terraform jq; do
  command -v "${command_name}" >/dev/null 2>&1 || die "Required command is missing: ${command_name}"
done
gcloud version --format=json 2>/dev/null |
  jq -e '."Google Cloud SDK" == "582.0.0"' >/dev/null ||
  die "Google Cloud CLI 582.0.0 is required."
gcloud auth application-default print-access-token >/dev/null 2>&1 ||
  die "Application Default Credentials are unavailable. Run gcloud auth application-default login as a human operator."

printf 'This will bootstrap project %s for repository %s.\n' "${PROJECT_ID}" "${GITHUB_REPOSITORY}"
printf 'Type the project ID to continue: '
IFS= read -r confirmation
[[ "${confirmation}" == "${PROJECT_ID}" ]] || die "Project confirmation did not match."

temporary_output=""
cleanup() {
  rm -f -- "${BACKEND_FILE}"
  if [[ -n "${temporary_output}" ]]; then
    rm -f -- "${temporary_output}"
  fi
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

terraform -chdir="${BOOTSTRAP_ROOT}" init -input=false -reconfigure
terraform -chdir="${BOOTSTRAP_ROOT}" apply -input=false -auto-approve \
  -var="project_id=${PROJECT_ID}" \
  -var="create_project=false" \
  -var="project_name=GKE Assessment" \
  -var="state_bucket_name=${STATE_BUCKET}" \
  -var="state_bucket_location=US" \
  -var="github_repository=${GITHUB_REPOSITORY}" \
  -var="github_owner_id=${GITHUB_OWNER_ID}" \
  -var="github_repository_id=${GITHUB_REPOSITORY_ID}"

install -m 0600 /dev/null "${BACKEND_FILE}"
printf '%s\n' 'terraform {' '  backend "gcs" {}' '}' >"${BACKEND_FILE}"
terraform -chdir="${BOOTSTRAP_ROOT}" init -input=false -force-copy \
  -backend-config="bucket=${STATE_BUCKET}" \
  -backend-config="prefix=bootstrap"

mkdir -p "${OUTPUT_DIR}"
temporary_output="$(mktemp "${OUTPUT_DIR}/bootstrap-outputs.XXXXXX")"
chmod 0600 "${temporary_output}"
terraform -chdir="${BOOTSTRAP_ROOT}" output -json |
  jq -e '{
    GCP_PROJECT_ID: .effective_project_id.value,
    GCP_PROJECT_NUMBER: (.project_number.value | tostring),
    GCP_WIF_PROVIDER: .wif_provider_resource_name.value,
    GCP_DEPLOYER_SERVICE_ACCOUNT: .pipeline_service_account_email.value,
    TF_STATE_BUCKET: .terraform_state_bucket.value
  }' >"${temporary_output}"
mv "${temporary_output}" "${OUTPUT_FILE}"
temporary_output=""
chmod 0600 "${OUTPUT_FILE}"
printf 'Non-secret bootstrap outputs were written to ignored file %s with mode 0600.\n' "${OUTPUT_FILE}"

if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  "${SCRIPT_DIR}/configure-github-variables.sh" \
    --repository "${GITHUB_REPOSITORY}" \
    --outputs "${OUTPUT_FILE}"
else
  printf 'GitHub CLI authentication is unavailable. Configure variables later with:\n  %q --repository %q --outputs %q\n' \
    "${SCRIPT_DIR}/configure-github-variables.sh" "${GITHUB_REPOSITORY}" "${OUTPUT_FILE}"
fi

printf '%s\n' 'Bootstrap complete. No service-account key or secret was created or copied to GitHub.'
