#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: configure-github-variables.sh --repository OWNER/REPO --outputs FILE

Configures exactly the non-secret repository variables used by deployment.
USAGE
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

require_value() {
  [[ -n "${2-}" ]] || die "$1 requires a non-empty value."
}

REPOSITORY=""
OUTPUTS_FILE=""

while (($# > 0)); do
  case "$1" in
    --repository)
      require_value "$1" "${2-}"
      REPOSITORY="$2"
      shift 2
      ;;
    --outputs)
      require_value "$1" "${2-}"
      OUTPUTS_FILE="$2"
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

[[ "${REPOSITORY}" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,37}[A-Za-z0-9])?/[A-Za-z0-9._-]{1,100}$ ]] ||
  die "--repository must have the form OWNER/REPO."
[[ -f "${OUTPUTS_FILE}" ]] || die "Outputs file does not exist: ${OUTPUTS_FILE}"
[[ "$(stat -c '%a' "${OUTPUTS_FILE}")" == "600" ]] ||
  die "Outputs file must have mode 0600."
command -v jq >/dev/null 2>&1 || die "Required command is missing: jq"

GCP_PROJECT_ID="$(jq -er '.GCP_PROJECT_ID | strings | select(length > 0)' "${OUTPUTS_FILE}")"
GCP_PROJECT_NUMBER="$(jq -er '.GCP_PROJECT_NUMBER | strings | select(length > 0)' "${OUTPUTS_FILE}")"
GCP_WIF_PROVIDER="$(jq -er '.GCP_WIF_PROVIDER | strings | select(length > 0)' "${OUTPUTS_FILE}")"
GCP_DEPLOYER_SERVICE_ACCOUNT="$(jq -er '.GCP_DEPLOYER_SERVICE_ACCOUNT | strings | select(length > 0)' "${OUTPUTS_FILE}")"
TF_STATE_BUCKET="$(jq -er '.TF_STATE_BUCKET | strings | select(length > 0)' "${OUTPUTS_FILE}")"

[[ "${GCP_PROJECT_ID}" =~ ^[a-z][a-z0-9-]{4,28}[a-z0-9]$ ]] || die "Invalid GCP_PROJECT_ID output."
[[ "${GCP_PROJECT_NUMBER}" =~ ^[1-9][0-9]{5,19}$ ]] || die "Invalid GCP_PROJECT_NUMBER output."
[[ "${GCP_WIF_PROVIDER}" =~ ^projects/[1-9][0-9]{5,19}/locations/global/workloadIdentityPools/[a-z0-9-]{4,32}/providers/[a-z0-9-]{4,32}$ ]] ||
  die "Invalid GCP_WIF_PROVIDER output."
[[ "${GCP_DEPLOYER_SERVICE_ACCOUNT}" =~ ^[a-z][a-z0-9-]{4,28}[a-z0-9]@[a-z][a-z0-9-]{4,28}[a-z0-9]\.iam\.gserviceaccount\.com$ ]] ||
  die "Invalid GCP_DEPLOYER_SERVICE_ACCOUNT output."
[[ "${TF_STATE_BUCKET}" =~ ^[a-z0-9][a-z0-9._-]{1,61}[a-z0-9]$ ]] || die "Invalid TF_STATE_BUCKET output."

variable_names=(
  GCP_PROJECT_ID
  GCP_PROJECT_NUMBER
  GCP_WIF_PROVIDER
  GCP_DEPLOYER_SERVICE_ACCOUNT
  TF_STATE_BUCKET
  GCP_REGION_PRIMARY
  GCP_REGION_SECONDARY
  GCP_ENABLE_HTTPS
  GCP_MANAGE_DNS
  GCP_CREATE_DNS_ZONE
  GCP_DNS_NAME
  GCP_DNS_ZONE_NAME
  GCP_DNS_ZONE_DNS_NAME
)
variable_values=(
  "${GCP_PROJECT_ID}"
  "${GCP_PROJECT_NUMBER}"
  "${GCP_WIF_PROVIDER}"
  "${GCP_DEPLOYER_SERVICE_ACCOUNT}"
  "${TF_STATE_BUCKET}"
  us-central1
  us-east1
  false
  false
  false
  ""
  ""
  ""
)

if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  for index in "${!variable_names[@]}"; do
    gh variable set "${variable_names[index]}" \
      --repo "${REPOSITORY}" \
      --body "${variable_values[index]}" >/dev/null
    printf 'Configured repository variable %s.\n' "${variable_names[index]}"
  done
else
  printf '%s\n' 'GitHub CLI authentication is unavailable. Run these non-secret commands manually:'
  for index in "${!variable_names[@]}"; do
    printf 'gh variable set %q --repo %q --body %q\n' \
      "${variable_names[index]}" "${REPOSITORY}" "${variable_values[index]}"
  done
fi

printf '%s\n' \
  'Recommended hardening remains manual: protect main and production/teardown environments, require reviewers with prevent-self-review, and add CODEOWNERS.'
