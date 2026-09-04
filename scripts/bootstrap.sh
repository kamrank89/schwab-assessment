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
LOCAL_STATE_BACKUP_FILE="${BOOTSTRAP_ROOT}/terraform.tfstate.backup"
ERRORED_STATE_FILE="${BOOTSTRAP_ROOT}/errored.tfstate"
LOCAL_WORKSPACE_STATE_DIR="${BOOTSTRAP_ROOT}/terraform.tfstate.d"
REMOTE_STATE_OBJECT="bootstrap/default.tfstate"
REMOTE_STATE_URI=""
export TF_DATA_DIR="${BOOTSTRAP_ROOT}/.terraform"
export TF_WORKSPACE="default"

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
LOCAL_STATE_PAYLOAD_FINGERPRINT=""
LOCAL_STATE_SERIAL=""
REMOTE_STATE_KIND="absent"
REMOTE_STATE_FINGERPRINT=""
REMOTE_STATE_PAYLOAD_FINGERPRINT=""
REMOTE_STATE_SERIAL=""
REMOTE_BUCKET_PRESENT="false"
remote_state_snapshot=""
adc_token_file=""

assert_default_workspace_safety() {
  local persisted_workspace_file="${TF_DATA_DIR}/environment"
  local persisted_workspace
  local -a workspace_entries
  local -a workspace_contents
  local workspace_entry

  if [[ -e "${TF_DATA_DIR}" || -L "${TF_DATA_DIR}" ]]; then
    [[ -d "${TF_DATA_DIR}" && ! -L "${TF_DATA_DIR}" ]] ||
      die "Terraform data path is not a regular directory; refusing bootstrap recovery."
  fi
  if [[ -e "${persisted_workspace_file}" || -L "${persisted_workspace_file}" ]]; then
    [[ -f "${persisted_workspace_file}" && ! -L "${persisted_workspace_file}" &&
      -r "${persisted_workspace_file}" ]] ||
      die "Persisted Terraform workspace selection is not a readable regular file."
    persisted_workspace="$(<"${persisted_workspace_file}")"
    [[ "${persisted_workspace}" == "default" ]] ||
      die "Persisted Terraform workspace is not default. Select and recover it manually before bootstrap."
  fi

  if [[ -e "${LOCAL_WORKSPACE_STATE_DIR}" || -L "${LOCAL_WORKSPACE_STATE_DIR}" ]]; then
    [[ -d "${LOCAL_WORKSPACE_STATE_DIR}" && ! -L "${LOCAL_WORKSPACE_STATE_DIR}" ]] ||
      die "Non-default Terraform workspace state path has a suspicious file type."
    shopt -s nullglob dotglob
    workspace_entries=("${LOCAL_WORKSPACE_STATE_DIR}"/*)
    for workspace_entry in "${workspace_entries[@]}"; do
      [[ -d "${workspace_entry}" && ! -L "${workspace_entry}" ]] ||
        die "Non-default Terraform workspace path contains a suspicious entry."
      workspace_contents=("${workspace_entry}"/*)
      ((${#workspace_contents[@]} == 0)) ||
        die "Non-default local Terraform workspace state exists under terraform.tfstate.d; recover it manually before bootstrap."
    done
    shopt -u nullglob dotglob
  fi
}

assert_no_errored_state() {
  if [[ -e "${ERRORED_STATE_FILE}" || -L "${ERRORED_STATE_FILE}" ]]; then
    die "infra/bootstrap/errored.tfstate exists. Review it and recover manually with 'terraform state push'; bootstrap will not use or delete it."
  fi
}

refresh_adc_token() {
  install -m 0600 /dev/null "${adc_token_file}"
  if ! gcloud auth application-default print-access-token >"${adc_token_file}" 2>/dev/null; then
    : >"${adc_token_file}"
    die "Application Default Credentials are unavailable. Run gcloud auth application-default login as a human operator."
  fi
  [[ -s "${adc_token_file}" ]] || die "Application Default Credentials returned an empty access token."
  chmod 0600 "${adc_token_file}"
}

validate_managed_state_contract() {
  local state_file="$1"
  local location="$2"
  local github_owner="${GITHUB_REPOSITORY%%/*}"
  local github_repository_name="${GITHUB_REPOSITORY#*/}"
  local expected_subject="repo:${github_owner}@${GITHUB_OWNER_ID}/${github_repository_name}@${GITHUB_REPOSITORY_ID}:ref:refs/heads/main"
  local expected_pipeline_email="assessment-deployer@${PROJECT_ID}.iam.gserviceaccount.com"
  local expected_provider_condition
  local state_project_number
  local expected_repository_member
  local expected_provider_audience

  expected_provider_condition="assertion.repository_id == '${GITHUB_REPOSITORY_ID}' && assertion.repository_owner_id == '${GITHUB_OWNER_ID}' && assertion.sub == '${expected_subject}'"

  jq -e --arg project "${PROJECT_ID}" --arg bucket "${STATE_BUCKET}" \
    --arg repository "${GITHUB_REPOSITORY}" --arg subject "${expected_subject}" '
      .outputs.effective_project_id.type == "string" and
      (.outputs.effective_project_id.value | type == "string") and
      .outputs.effective_project_id.value == $project and
      .outputs.terraform_state_bucket.type == "string" and
      (.outputs.terraform_state_bucket.value | type == "string") and
      .outputs.terraform_state_bucket.value == $bucket and
      .outputs.github_repository.type == "string" and
      (.outputs.github_repository.value | type == "string") and
      .outputs.github_repository.value == $repository and
      .outputs.allowed_subject.type == "string" and
      (.outputs.allowed_subject.value | type == "string") and
      .outputs.allowed_subject.value == $subject
    ' "${state_file}" >/dev/null ||
    die "The ${location} resource-bearing state lacks exact typed bootstrap ownership outputs; manual recovery is required."

  state_project_number="$(jq -er '
    select(.outputs.project_number.type == "string") |
    .outputs.project_number.value |
    select(type == "string" and test("^[1-9][0-9]{5,19}$"))
  ' "${state_file}")" ||
    die "The ${location} resource-bearing state lacks a typed numeric project-number output; manual recovery is required."
  expected_repository_member="principalSet://iam.googleapis.com/projects/${state_project_number}/locations/global/workloadIdentityPools/github-actions/attribute.repository_id/${GITHUB_REPOSITORY_ID}"
  expected_provider_audience="https://iam.googleapis.com/projects/${state_project_number}/locations/global/workloadIdentityPools/github-actions/providers/github"

  jq -e '
      [
        ["data", "google_project", "effective"],
        ["managed", "google_project", "assessment"],
        ["managed", "google_project_service", "required"],
        ["managed", "google_storage_bucket", "terraform_state"],
        ["managed", "google_service_account", "pipeline"],
        ["managed", "google_service_account_iam_member", "github_repository"],
        ["managed", "google_project_iam_member", "pipeline"],
        ["managed", "google_storage_bucket_iam_member", "pipeline"],
        ["managed", "google_iam_workload_identity_pool", "github_actions"],
        ["managed", "google_iam_workload_identity_pool_provider", "github"]
      ] as $allowed |
      all(.resources[];
        (.module? == null) and
        .provider == "provider[\"registry.terraform.io/hashicorp/google\"]" and
        ([.mode, .type, .name] as $signature | any($allowed[]; . == $signature)) and
        (.instances | type == "array" and length > 0) and
        all(.instances[];
          (.attributes | type == "object") and
          ((.deposed? // null) == null) and
          ((.status? // "ready") == "ready")
        )
      )
    ' "${state_file}" >/dev/null ||
    die "The ${location} resource-bearing state contains an unexpected bootstrap resource signature or incomplete instance; manual recovery is required."

  jq -e '
      .resources as $resources |
      [
        ["data", "google_project", "effective"],
        ["managed", "google_project_service", "required"],
        ["managed", "google_storage_bucket", "terraform_state"],
        ["managed", "google_service_account", "pipeline"],
        ["managed", "google_service_account_iam_member", "github_repository"],
        ["managed", "google_project_iam_member", "pipeline"],
        ["managed", "google_storage_bucket_iam_member", "pipeline"],
        ["managed", "google_iam_workload_identity_pool", "github_actions"],
        ["managed", "google_iam_workload_identity_pool_provider", "github"]
      ] as $required |
      all($required[];
        . as $required_signature |
        any($resources[]; [.mode, .type, .name] == $required_signature)
      )
    ' "${state_file}" >/dev/null ||
    die "The ${location} resource-bearing state is a partial or older bootstrap state without all core anchors; manual recovery is required."

  jq -e --arg project "${PROJECT_ID}" --arg bucket "${STATE_BUCKET}" \
    --arg pipeline_email "${expected_pipeline_email}" \
    --arg repository_member "${expected_repository_member}" \
    --arg provider_condition "${expected_provider_condition}" \
    --arg provider_audience "${expected_provider_audience}" '
      [
        "cloudbilling.googleapis.com",
        "cloudresourcemanager.googleapis.com",
        "iam.googleapis.com",
        "iamcredentials.googleapis.com",
        "serviceusage.googleapis.com",
        "storage.googleapis.com",
        "sts.googleapis.com"
      ] as $services |
      [
        "roles/bigquery.admin",
        "roles/compute.admin",
        "roles/container.admin",
        "roles/dns.admin",
        "roles/gkehub.admin",
        "roles/gkehub.gatewayAdmin",
        "roles/gkehub.viewer",
        "roles/iam.serviceAccountAdmin",
        "roles/logging.configWriter",
        "roles/monitoring.viewer",
        "roles/resourcemanager.projectIamAdmin",
        "roles/secretmanager.admin",
        "roles/serviceusage.serviceUsageAdmin"
      ] as $project_roles |
      ["roles/storage.legacyBucketReader", "roles/storage.objectAdmin"] as $bucket_roles |
      all(.resources[];
        .mode as $mode | .type as $type | .name as $name |
        all(.instances[];
          .attributes as $a |
          if $mode == "data" and $type == "google_project" and $name == "effective" then
            $a.project_id == $project
          elif $type == "google_project" and $name == "assessment" then
            $a.project_id == $project and $a.deletion_policy == "ABANDON"
          elif $type == "google_project_service" and $name == "required" then
            $a.project == $project and .index_key == $a.service and ($services | index($a.service)) != null
          elif $type == "google_storage_bucket" and $name == "terraform_state" then
            $a.name == $bucket and $a.project == $project
          elif $type == "google_service_account" and $name == "pipeline" then
            $a.project == $project and $a.account_id == "assessment-deployer" and $a.email == $pipeline_email
          elif $type == "google_service_account_iam_member" and $name == "github_repository" then
            $a.role == "roles/iam.workloadIdentityUser" and
            $a.member == $repository_member and
            ($a.service_account_id | endswith("/serviceAccounts/" + $pipeline_email))
          elif $type == "google_project_iam_member" and $name == "pipeline" then
            $a.project == $project and $a.member == ("serviceAccount:" + $pipeline_email) and
            .index_key == $a.role and
            ($project_roles | index($a.role)) != null
          elif $type == "google_storage_bucket_iam_member" and $name == "pipeline" then
            ($a.bucket == $bucket or $a.bucket == ("b/" + $bucket)) and
            $a.member == ("serviceAccount:" + $pipeline_email) and
            .index_key == $a.role and
            ($bucket_roles | index($a.role)) != null
          elif $type == "google_iam_workload_identity_pool" and $name == "github_actions" then
            $a.project == $project and $a.workload_identity_pool_id == "github-actions"
          elif $type == "google_iam_workload_identity_pool_provider" and $name == "github" then
            $a.project == $project and $a.workload_identity_pool_id == "github-actions" and
            $a.workload_identity_pool_provider_id == "github" and
            $a.attribute_condition == $provider_condition and
            $a.oidc[0].issuer_uri == "https://token.actions.githubusercontent.com" and
            ($a.oidc[0].allowed_audiences | type == "array" and . == [$provider_audience])
          else false
          end
        )
      )
    ' "${state_file}" >/dev/null ||
    die "The ${location} resource-bearing state contains bootstrap resources bound to unexpected cloud identities; manual recovery is required."

  jq -e '
      def keys_for($type; $name):
        [.resources[] | select(.mode == "managed" and .type == $type and .name == $name) |
          .instances[].index_key] | sort;
      def instance_count($mode; $type; $name):
        [.resources[] | select(.mode == $mode and .type == $type and .name == $name) |
          .instances[]] | length;
      instance_count("data"; "google_project"; "effective") == 1 and
      instance_count("managed"; "google_project"; "assessment") <= 1 and
      instance_count("managed"; "google_storage_bucket"; "terraform_state") == 1 and
      instance_count("managed"; "google_service_account"; "pipeline") == 1 and
      instance_count("managed"; "google_service_account_iam_member"; "github_repository") == 1 and
      instance_count("managed"; "google_iam_workload_identity_pool"; "github_actions") == 1 and
      instance_count("managed"; "google_iam_workload_identity_pool_provider"; "github") == 1 and
      keys_for("google_project_service"; "required") == ([
        "cloudbilling.googleapis.com",
        "cloudresourcemanager.googleapis.com",
        "iam.googleapis.com",
        "iamcredentials.googleapis.com",
        "serviceusage.googleapis.com",
        "storage.googleapis.com",
        "sts.googleapis.com"
      ] | sort) and
      keys_for("google_project_iam_member"; "pipeline") == ([
        "roles/bigquery.admin",
        "roles/compute.admin",
        "roles/container.admin",
        "roles/dns.admin",
        "roles/gkehub.admin",
        "roles/gkehub.gatewayAdmin",
        "roles/gkehub.viewer",
        "roles/iam.serviceAccountAdmin",
        "roles/logging.configWriter",
        "roles/monitoring.viewer",
        "roles/resourcemanager.projectIamAdmin",
        "roles/secretmanager.admin",
        "roles/serviceusage.serviceUsageAdmin"
      ] | sort) and
      keys_for("google_storage_bucket_iam_member"; "pipeline") == ([
        "roles/storage.legacyBucketReader",
        "roles/storage.objectAdmin"
      ] | sort)
    ' "${state_file}" >/dev/null ||
    die "The ${location} resource-bearing state has incomplete or unexpected bootstrap for_each instances; manual recovery is required."
}

inspect_state_file() {
  local state_file="$1"
  local location="$2"
  local resource_count
  local fingerprint
  local payload_fingerprint
  local serial

  if [[ ! -e "${state_file}" ]]; then
    case "${location}" in
      local)
        LOCAL_STATE_KIND="absent"
        LOCAL_STATE_FINGERPRINT=""
        LOCAL_STATE_PAYLOAD_FINGERPRINT=""
        LOCAL_STATE_SERIAL=""
        ;;
      remote)
        REMOTE_STATE_KIND="absent"
        REMOTE_STATE_FINGERPRINT=""
        REMOTE_STATE_PAYLOAD_FINGERPRINT=""
        REMOTE_STATE_SERIAL=""
        ;;
      *) die "Internal state-location error." ;;
    esac
    return 0
  fi
  [[ -f "${state_file}" && -r "${state_file}" ]] ||
    die "The ${location} bootstrap state snapshot is not a readable regular file."
  jq -e '
    type == "object" and
    .version == 4 and
    (.serial | type == "number" and . >= 0 and . == floor) and
    (.lineage | type == "string" and length > 0) and
    ((.resources // []) | type == "array")
  ' "${state_file}" >/dev/null || die "The ${location} bootstrap state snapshot is malformed."

  resource_count="$(jq -er '(.resources // []) | length' "${state_file}")"
  if ((resource_count > 0)); then
    validate_managed_state_contract "${state_file}" "${location}"
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
  read -r payload_fingerprint _ < <(
    jq -cS '{
      lineage,
      outputs: (.outputs // {}),
      resources: (.resources // [])
    }' "${state_file}" | sha256sum
  )
  [[ "${payload_fingerprint}" =~ ^[a-f0-9]{64}$ ]] ||
    die "Could not fingerprint ${location} bootstrap state payload."
  serial="$(jq -er '.serial | tostring' "${state_file}")"

  case "${location}" in
    local)
      LOCAL_STATE_FINGERPRINT="${fingerprint}"
      LOCAL_STATE_PAYLOAD_FINGERPRINT="${payload_fingerprint}"
      LOCAL_STATE_SERIAL="${serial}"
      if ((resource_count > 0)); then
        LOCAL_STATE_KIND="managed"
      else
        LOCAL_STATE_KIND="empty"
      fi
      ;;
    remote)
      REMOTE_STATE_FINGERPRINT="${fingerprint}"
      REMOTE_STATE_PAYLOAD_FINGERPRINT="${payload_fingerprint}"
      REMOTE_STATE_SERIAL="${serial}"
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
  if [[ -f "${LOCAL_STATE_FILE}" && ! -L "${LOCAL_STATE_FILE}" &&
    -r "${LOCAL_STATE_FILE}" && ! -s "${LOCAL_STATE_FILE}" ]]; then
    [[ -f "${LOCAL_STATE_BACKUP_FILE}" && ! -L "${LOCAL_STATE_BACKUP_FILE}" &&
      -r "${LOCAL_STATE_BACKUP_FILE}" ]] ||
      die "The local bootstrap state is an empty migration stub without a readable regular backup; manual recovery is required."
    inspect_state_file "${LOCAL_STATE_BACKUP_FILE}" local
    [[ "${LOCAL_STATE_KIND}" == "managed" ]] ||
      die "The local bootstrap state is an empty migration stub without a managed backup; manual recovery is required."
    LOCAL_STATE_KIND="migration_stub"
    return 0
  fi
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
  refresh_adc_token
  if ! bucket_inventory="$(gcloud --access-token-file="${adc_token_file}" storage buckets list \
    --project="${PROJECT_ID}" --format=json 2>/dev/null)"; then
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

  refresh_adc_token
  if ! object_inventory="$(gcloud --access-token-file="${adc_token_file}" storage objects list \
    "gs://${STATE_BUCKET}/bootstrap/**" --format=json 2>/dev/null)"; then
    die "Could not inspect state objects; refusing to treat an access or API error as absence."
  fi
  object_count="$(jq -er --arg object "${REMOTE_STATE_OBJECT}" \
    '[.[] | select(.name == $object and .noncurrent_time? == null)] | length' \
    <<<"${object_inventory}")"
  [[ "${object_count}" == "0" || "${object_count}" == "1" ]] ||
    die "Remote bootstrap state discovery returned an ambiguous result."
  if [[ "${object_count}" == "0" ]]; then
    return 0
  fi

  install -m 0600 /dev/null "${remote_state_snapshot}"
  refresh_adc_token
  if ! gcloud --access-token-file="${adc_token_file}" storage cat \
    "${REMOTE_STATE_URI}" >"${remote_state_snapshot}" 2>/dev/null; then
    die "Remote bootstrap state exists but could not be read."
  fi
  inspect_state_file "${remote_state_snapshot}" remote
}

states_are_identical() {
  [[ -n "${LOCAL_STATE_FINGERPRINT}" &&
    "${LOCAL_STATE_FINGERPRINT}" == "${REMOTE_STATE_FINGERPRINT}" ]]
}

migration_stub_matches_remote() {
  [[ -n "${LOCAL_STATE_PAYLOAD_FINGERPRINT}" &&
    "${LOCAL_STATE_PAYLOAD_FINGERPRINT}" == "${REMOTE_STATE_PAYLOAD_FINGERPRINT}" &&
    "${LOCAL_STATE_SERIAL}" =~ ^[0-9]+$ && "${REMOTE_STATE_SERIAL}" =~ ^[0-9]+$ ]] &&
    ((REMOTE_STATE_SERIAL >= LOCAL_STATE_SERIAL))
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
    migration_stub)
      inspect_remote_state
      if [[ "${REMOTE_STATE_KIND}" != "managed" ]] || ! migration_stub_matches_remote; then
        die "Local migration backup no longer matches remote state; refusing to remove the migration stub."
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

temporary_root="$(mktemp -d "${TMPDIR:-/tmp}/gke-assessment-bootstrap.XXXXXX")"
chmod 0700 "${temporary_root}"
remote_state_snapshot="${temporary_root}/remote-bootstrap.tfstate"
adc_token_file="${temporary_root}/adc-access-token"
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

assert_default_workspace_safety
assert_no_errored_state
refresh_adc_token
inspect_local_state
inspect_remote_state
selected_backend=""
case "${LOCAL_STATE_KIND}:${REMOTE_STATE_KIND}" in
  managed:managed)
    states_are_identical ||
      die "Local and remote bootstrap states both manage resources but differ; manual state recovery is required."
    selected_backend="remote"
    ;;
  migration_stub:managed)
    migration_stub_matches_remote ||
      die "The local migration backup differs from remote state; manual state recovery is required."
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
