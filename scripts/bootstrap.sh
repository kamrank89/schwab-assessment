#!/usr/bin/env bash
set -euo pipefail

umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd -P)"
BOOTSTRAP_ROOT="${REPO_ROOT}/infra/bootstrap"
OUTPUT_DIR="${REPO_ROOT}/.generated"
OUTPUT_FILE="${OUTPUT_DIR}/bootstrap-outputs.json"
BACKEND_FILE="${BOOTSTRAP_ROOT}/backend.generated.tf"
LOCAL_STATE_FILE="${BOOTSTRAP_ROOT}/terraform.tfstate"
REMOTE_STATE_OBJECT="bootstrap/default.tfstate"
REMOTE_STATE_URI=""

usage() {
  cat <<'USAGE'
Usage: bootstrap.sh --project-id ID --state-bucket BUCKET \
  --github-repository OWNER/REPO --github-owner-id ID \
  --github-repository-id ID

This is a human-credential bootstrap. Safe reruns inspect local and remote state.
It cannot run in GitHub Actions.
USAGE
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

require_value() {
  [[ -n "${2-}" ]] || die "$1 requires a non-empty value."
}

LOCAL_STATE_KIND="absent"
LOCAL_STATE_FINGERPRINT=""
REMOTE_STATE_KIND="absent"
REMOTE_STATE_FINGERPRINT=""
REMOTE_BUCKET_PRESENT="false"
remote_state_snapshot=""

inspect_state_file() {
  local state_file="$1"
  local location="$2"
  local resource_count
  local fingerprint
  local state_project
  local state_bucket

  if [[ ! -e "${state_file}" ]]; then
    case "${location}" in
      local)
        LOCAL_STATE_KIND="absent"
        LOCAL_STATE_FINGERPRINT=""
        ;;
      remote)
        REMOTE_STATE_KIND="absent"
        REMOTE_STATE_FINGERPRINT=""
        ;;
      *) die "Internal state-location error." ;;
    esac
    return 0
  fi
  [[ -f "${state_file}" && -r "${state_file}" ]] ||
    die "The ${location} bootstrap state snapshot is not a readable regular file."
  jq -e '
    type == "object" and
    (.version | type == "number") and
    (.serial | type == "number") and
    (.lineage | type == "string" and length > 0) and
    ((.resources // []) | type == "array")
  ' "${state_file}" >/dev/null || die "The ${location} bootstrap state snapshot is malformed."

  resource_count="$(jq -er '(.resources // []) | length' "${state_file}")"
  state_project="$(jq -r '.outputs.effective_project_id.value // ""' "${state_file}")"
  state_bucket="$(jq -r '.outputs.terraform_state_bucket.value // ""' "${state_file}")"
  if [[ -n "${state_project}" && "${state_project}" != "${PROJECT_ID}" ]]; then
    die "The ${location} bootstrap state belongs to a different project."
  fi
  if [[ -n "${state_bucket}" && "${state_bucket}" != "${STATE_BUCKET}" ]]; then
    die "The ${location} bootstrap state belongs to a different state bucket."
  fi
  read -r fingerprint _ < <(
    jq -cS '{
      lineage,
      serial,
      outputs: (.outputs // {}),
      resources: (.resources // [])
    }' "${state_file}" | sha256sum
  )
  [[ "${fingerprint}" =~ ^[a-f0-9]{64}$ ]] || die "Could not fingerprint ${location} bootstrap state."

  case "${location}" in
    local)
      LOCAL_STATE_FINGERPRINT="${fingerprint}"
      if ((resource_count > 0)); then
        LOCAL_STATE_KIND="managed"
      else
        LOCAL_STATE_KIND="empty"
      fi
      ;;
    remote)
      REMOTE_STATE_FINGERPRINT="${fingerprint}"
      if ((resource_count > 0)); then
        REMOTE_STATE_KIND="managed"
      else
        REMOTE_STATE_KIND="empty"
      fi
      ;;
    *) die "Internal state-location error." ;;
  esac
}

inspect_local_state() {
  inspect_state_file "${LOCAL_STATE_FILE}" local
}

inspect_remote_state() {
  local bucket_inventory
  local bucket_count
  local object_inventory
  local object_count

  REMOTE_BUCKET_PRESENT="false"
  REMOTE_STATE_KIND="absent"
  REMOTE_STATE_FINGERPRINT=""
  if ! bucket_inventory="$(gcloud storage buckets list --project="${PROJECT_ID}" --format=json 2>/dev/null)"; then
    die "Could not inspect the state bucket; refusing to treat an access or API error as absence."
  fi
  bucket_count="$(jq -er --arg bucket "${STATE_BUCKET}" \
    '[.[] | select(.name == $bucket)] | length' <<<"${bucket_inventory}")"
  [[ "${bucket_count}" == "0" || "${bucket_count}" == "1" ]] ||
    die "State bucket discovery returned an ambiguous result."
  if [[ "${bucket_count}" == "0" ]]; then
    return 0
  fi
  REMOTE_BUCKET_PRESENT="true"

  if ! object_inventory="$(gcloud storage objects list "gs://${STATE_BUCKET}" --format=json 2>/dev/null)"; then
    die "Could not inspect state objects; refusing to treat an access or API error as absence."
  fi
  object_count="$(jq -er --arg object "${REMOTE_STATE_OBJECT}" \
    '[.[] | select(.name == $object)] | length' <<<"${object_inventory}")"
  [[ "${object_count}" == "0" || "${object_count}" == "1" ]] ||
    die "Remote bootstrap state discovery returned an ambiguous result."
  if [[ "${object_count}" == "0" ]]; then
    return 0
  fi

  install -m 0600 /dev/null "${remote_state_snapshot}"
  if ! gcloud storage cat "${REMOTE_STATE_URI}" >"${remote_state_snapshot}" 2>/dev/null; then
    die "Remote bootstrap state exists but could not be read."
  fi
  inspect_state_file "${remote_state_snapshot}" remote
}

states_are_identical() {
  [[ -n "${LOCAL_STATE_FINGERPRINT}" &&
    "${LOCAL_STATE_FINGERPRINT}" == "${REMOTE_STATE_FINGERPRINT}" ]]
}

write_ephemeral_backend() {
  install -m 0600 /dev/null "${BACKEND_FILE}"
  printf '%s\n' 'terraform {' '  backend "gcs" {}' '}' >"${BACKEND_FILE}"
}

retire_duplicate_local_state() {
  inspect_local_state
  case "${LOCAL_STATE_KIND}" in
    absent) return 0 ;;
    empty)
      rm -f -- "${LOCAL_STATE_FILE}"
      ;;
    managed)
      inspect_remote_state
      if [[ "${REMOTE_STATE_KIND}" != "managed" ]] || ! states_are_identical; then
        die "Local state is no longer an exact duplicate of remote state; refusing to remove it."
      fi
      rm -f -- "${LOCAL_STATE_FILE}"
      ;;
    *) die "Internal local-state classification error." ;;
  esac
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
REMOTE_STATE_URI="gs://${STATE_BUCKET}/${REMOTE_STATE_OBJECT}"

for command_name in gcloud terraform jq sha256sum; do
  command -v "${command_name}" >/dev/null 2>&1 || die "Required command is missing: ${command_name}"
done
gcloud version --format=json 2>/dev/null |
  jq -e '."Google Cloud SDK" == "582.0.0"' >/dev/null ||
  die "Google Cloud CLI 582.0.0 is required."
gcloud auth application-default print-access-token >/dev/null 2>&1 ||
  die "Application Default Credentials are unavailable. Run gcloud auth application-default login as a human operator."

temporary_root="$(mktemp -d "${TMPDIR:-/tmp}/gke-assessment-bootstrap.XXXXXX")"
chmod 0700 "${temporary_root}"
remote_state_snapshot="${temporary_root}/remote-bootstrap.tfstate"
temporary_output=""
cleanup() {
  rm -f -- "${BACKEND_FILE}"
  if [[ -n "${temporary_output}" ]]; then
    rm -f -- "${temporary_output}"
  fi
  rm -rf -- "${temporary_root}"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

inspect_local_state
inspect_remote_state
selected_backend=""
case "${LOCAL_STATE_KIND}:${REMOTE_STATE_KIND}" in
  managed:managed)
    states_are_identical ||
      die "Local and remote bootstrap states both manage resources but differ; manual state recovery is required."
    selected_backend="remote"
    ;;
  managed:absent|managed:empty)
    selected_backend="local"
    ;;
  absent:managed|empty:managed)
    selected_backend="remote"
    ;;
  absent:absent|absent:empty|empty:absent|empty:empty)
    if [[ "${REMOTE_BUCKET_PRESENT}" == "true" ]]; then
      selected_backend="remote"
    else
      selected_backend="local"
    fi
    ;;
  *) die "Bootstrap state classification is ambiguous; refusing to continue." ;;
esac

printf 'This will bootstrap project %s for repository %s.\n' "${PROJECT_ID}" "${GITHUB_REPOSITORY}"
printf 'Selected the %s bootstrap state after local and remote state inspection.\n' "${selected_backend}"
printf 'Type the project ID to continue: '
IFS= read -r confirmation
[[ "${confirmation}" == "${PROJECT_ID}" ]] || die "Project confirmation did not match."

terraform_variables=(
  -var="project_id=${PROJECT_ID}"
  -var="create_project=false"
  -var="project_name=GKE Assessment"
  -var="state_bucket_name=${STATE_BUCKET}"
  -var="state_bucket_location=US"
  -var="github_repository=${GITHUB_REPOSITORY}"
  -var="github_owner_id=${GITHUB_OWNER_ID}"
  -var="github_repository_id=${GITHUB_REPOSITORY_ID}"
)

if [[ "${selected_backend}" == "remote" ]]; then
  write_ephemeral_backend
  terraform -chdir="${BOOTSTRAP_ROOT}" init -input=false -reconfigure \
    -backend-config="bucket=${STATE_BUCKET}" \
    -backend-config="prefix=bootstrap"
  inspect_remote_state
  if [[ "${LOCAL_STATE_KIND}" == "managed" ]]; then
    if [[ "${REMOTE_STATE_KIND}" != "managed" ]] || ! states_are_identical; then
      die "Remote state changed after selection; refusing to apply or remove local state."
    fi
  fi
  retire_duplicate_local_state
  terraform -chdir="${BOOTSTRAP_ROOT}" apply -input=false -auto-approve "${terraform_variables[@]}"
  inspect_remote_state
  [[ "${REMOTE_STATE_KIND}" == "managed" ]] ||
    die "Remote bootstrap apply completed without a managed remote state snapshot."
else
  rm -f -- "${BACKEND_FILE}"
  terraform -chdir="${BOOTSTRAP_ROOT}" init -input=false -reconfigure
  terraform -chdir="${BOOTSTRAP_ROOT}" apply -input=false -auto-approve "${terraform_variables[@]}"
  inspect_local_state
  [[ "${LOCAL_STATE_KIND}" == "managed" ]] ||
    die "Local bootstrap apply completed without a managed local state snapshot."
  inspect_remote_state
  if [[ "${REMOTE_STATE_KIND}" == "managed" ]]; then
    states_are_identical ||
      die "Remote bootstrap state appeared and conflicts with local state; refusing migration."
    write_ephemeral_backend
    terraform -chdir="${BOOTSTRAP_ROOT}" init -input=false -reconfigure \
      -backend-config="bucket=${STATE_BUCKET}" \
      -backend-config="prefix=bootstrap"
  else
    write_ephemeral_backend
    terraform -chdir="${BOOTSTRAP_ROOT}" init -input=false -force-copy \
      -backend-config="bucket=${STATE_BUCKET}" \
      -backend-config="prefix=bootstrap"
  fi
  inspect_remote_state
  if [[ "${REMOTE_STATE_KIND}" != "managed" ]] || ! states_are_identical; then
    die "Bootstrap state migration did not produce an exact managed remote copy."
  fi
  retire_duplicate_local_state
fi

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
