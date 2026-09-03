#!/usr/bin/env bash
set -euo pipefail
set +x

umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd -P)"
PRIMARY_CLUSTER="gke-assessment-us-central1"
SECONDARY_CLUSTER="gke-assessment-us-east1"
PRIMARY_REGION="us-central1"
SECONDARY_REGION="us-east1"
LOAD_BALANCER_TIMEOUT_SECONDS=1800
MCI_NAMESPACE="assessment"
MCI_NAME="assessment-ingress"
INVENTORY_DIR="${REPO_ROOT}/.generated"
INVENTORY_FILE=""
REMOTE_INVENTORY_OBJECT=""
REMOTE_INVENTORY_URI=""
REMOTE_INVENTORY_PRESENT="false"
REMOTE_INVENTORY_GENERATION=""
LOCAL_INVENTORY_PRESENT="false"
COMPLETION_MARKER_OBJECT=""
COMPLETION_MARKER_URI=""
COMPLETION_MARKER_GENERATION=""

usage() {
  cat <<'USAGE'
Usage: teardown.sh --project-id ID --confirmation "DESTROY ID"

Deletes Kubernetes assessment resources, then destroys platform and foundation.
Bootstrap state, WIF, the deployer identity, and the state bucket are retained.
USAGE
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Required command is missing: $1"
}

refresh_adc_token() {
  install -m 0600 /dev/null "${adc_token_file}"
  if ! gcloud auth application-default print-access-token >"${adc_token_file}" 2>/dev/null; then
    : >"${adc_token_file}"
    die "Application Default Credentials are unavailable; teardown storage inspection cannot use the Terraform identity."
  fi
  [[ -s "${adc_token_file}" ]] || die "Application Default Credentials returned an empty access token."
  chmod 0600 "${adc_token_file}"
}

PROJECT_ID=""
CONFIRMATION=""

while (($# > 0)); do
  case "$1" in
    --project-id)
      [[ -n "${2-}" ]] || die "--project-id requires a non-empty value."
      PROJECT_ID="$2"
      shift 2
      ;;
    --confirmation)
      [[ -n "${2-}" ]] || die "--confirmation requires a non-empty value."
      CONFIRMATION="$2"
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

[[ "${PROJECT_ID}" =~ ^[a-z][a-z0-9-]{4,28}[a-z0-9]$ ]] || die "Invalid project ID."
[[ -n "${GCP_PROJECT_ID:-}" ]] || die "GCP_PROJECT_ID is required."
[[ "${PROJECT_ID}" == "${GCP_PROJECT_ID}" ]] || die "Dispatched project ID does not match GCP_PROJECT_ID."
[[ "${CONFIRMATION}" == "DESTROY ${PROJECT_ID}" ]] ||
  die "Confirmation must be exactly: DESTROY ${PROJECT_ID}"
[[ -n "${TF_STATE_BUCKET:-}" ]] || die "TF_STATE_BUCKET is required."
[[ "${TF_STATE_BUCKET}" =~ ^[a-z0-9][a-z0-9._-]{1,61}[a-z0-9]$ ]] || die "Invalid TF_STATE_BUCKET."
[[ -n "${GCP_WIF_PROVIDER:-}" ]] || die "GCP_WIF_PROVIDER is required for the retained-resource report."
[[ -n "${GCP_DEPLOYER_SERVICE_ACCOUNT:-}" ]] ||
  die "GCP_DEPLOYER_SERVICE_ACCOUNT is required for the retained-resource report."
INVENTORY_FILE="${INVENTORY_DIR}/teardown-controller-inventory-${PROJECT_ID}.json"
REMOTE_INVENTORY_OBJECT="recovery/teardown-controller-inventory-${PROJECT_ID}.json"
REMOTE_INVENTORY_URI="gs://${TF_STATE_BUCKET}/${REMOTE_INVENTORY_OBJECT}"
COMPLETION_MARKER_OBJECT="recovery/teardown-completion-${PROJECT_ID}.json"
COMPLETION_MARKER_URI="gs://${TF_STATE_BUCKET}/${COMPLETION_MARKER_OBJECT}"

if [[ "${GITHUB_ACTIONS:-false}" == "true" ]]; then
  [[ "${GITHUB_REF:-}" == "refs/heads/main" ]] || die "Teardown may run only from the main branch."
else
  [[ "$(git -C "${REPO_ROOT}" branch --show-current)" == "main" ]] ||
    die "Teardown may run only from the main branch."
fi

for command_name in git terraform jq gcloud kubectl sha256sum stat ln; do
  require_command "${command_name}"
done

temporary_root="$(mktemp -d "${TMPDIR:-/tmp}/gke-assessment-teardown.XXXXXX")"
chmod 0700 "${temporary_root}"
inventory_candidate=""
remote_inventory_snapshot="${temporary_root}/remote-controller-inventory.json"
completion_marker_snapshot="${temporary_root}/teardown-completion.json"
adc_token_file="${temporary_root}/adc-access-token"
cleanup() {
  if [[ -n "${inventory_candidate}" ]]; then
    rm -f -- "${inventory_candidate}"
  fi
  rm -rf -- "${temporary_root}"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

prepare_kubeconfig() {
  install -m 0600 /dev/null "$1"
}

get_dns_credentials() {
  local cluster="$1"
  local region="$2"
  local kubeconfig="$3"

  prepare_kubeconfig "${kubeconfig}"
  KUBECONFIG="${kubeconfig}" gcloud container clusters get-credentials "${cluster}" \
    --region="${region}" --project="${PROJECT_ID}" --dns-endpoint --quiet >/dev/null
  chmod 0600 "${kubeconfig}"
}

normalize_resource_name() {
  local raw_name="$1"
  local resource_name

  raw_name="${raw_name#"${raw_name%%[![:space:]]*}"}"
  raw_name="${raw_name%"${raw_name##*[![:space:]]}"}"
  raw_name="${raw_name#\"}"
  raw_name="${raw_name%\"}"
  raw_name="${raw_name#\'}"
  raw_name="${raw_name%\'}"
  raw_name="${raw_name%%\?*}"
  raw_name="${raw_name%/}"
  resource_name="${raw_name##*/}"
  [[ "${resource_name}" =~ ^[a-z]([a-z0-9-]{0,61}[a-z0-9])?$ ]] ||
    die "MultiClusterIngress status contains an invalid controller resource reference."
  printf '%s\n' "${resource_name}"
}

append_status_inventory() {
  local mci_json="$1"
  local resource_kind="$2"
  local jq_selector="$3"
  local destination="$4"
  local value_type
  local raw_values
  local raw_value
  local resource_name
  local count=0

  value_type="$(jq -r "(${jq_selector}) | type" <<<"${mci_json}")"
  [[ "${value_type}" == "string" || "${value_type}" == "array" ]] ||
    die "MultiClusterIngress status does not expose required ${resource_kind} inventory."
  raw_values="$(jq -r "(${jq_selector}) |
    if type == \"array\" then .[]
    elif type == \"string\" then split(\",\")[]
    else empty
    end" <<<"${mci_json}")"
  while IFS= read -r raw_value; do
    [[ -n "${raw_value}" ]] || continue
    resource_name="$(normalize_resource_name "${raw_value}")"
    printf '%s\tglobal\tglobal\t%s\n' "${resource_kind}" "${resource_name}" >>"${destination}"
    count=$((count + 1))
  done <<<"${raw_values}"
  ((count > 0)) || die "MultiClusterIngress status exposes empty ${resource_kind} inventory."
}

COMPUTE_INVENTORY_JSON=""
LOOKUP_RESOURCE_JSON=""

load_compute_inventory() {
  local resource_kind="$1"

  case "${resource_kind}" in
    forwarding-rule)
      COMPUTE_INVENTORY_JSON="$(gcloud compute forwarding-rules list --global \
        --project="${PROJECT_ID}" --format=json 2>/dev/null)" ||
        die "Could not inspect controller forwarding rules."
      ;;
    target-http-proxy)
      COMPUTE_INVENTORY_JSON="$(gcloud compute target-http-proxies list --global \
        --project="${PROJECT_ID}" --format=json 2>/dev/null)" ||
        die "Could not inspect controller HTTP target proxies."
      ;;
    target-https-proxy)
      COMPUTE_INVENTORY_JSON="$(gcloud compute target-https-proxies list --global \
        --project="${PROJECT_ID}" --format=json 2>/dev/null)" ||
        die "Could not inspect controller HTTPS target proxies."
      ;;
    url-map)
      COMPUTE_INVENTORY_JSON="$(gcloud compute url-maps list --global \
        --project="${PROJECT_ID}" --format=json 2>/dev/null)" ||
        die "Could not inspect controller URL maps."
      ;;
    health-check)
      COMPUTE_INVENTORY_JSON="$(gcloud compute health-checks list --global \
        --project="${PROJECT_ID}" --format=json 2>/dev/null)" ||
        die "Could not inspect controller health checks."
      ;;
    backend-service)
      COMPUTE_INVENTORY_JSON="$(gcloud compute backend-services list --global \
        --project="${PROJECT_ID}" --format=json 2>/dev/null)" ||
        die "Could not inspect controller backend services."
      ;;
    firewall-rule)
      COMPUTE_INVENTORY_JSON="$(gcloud compute firewall-rules list \
        --project="${PROJECT_ID}" --format=json 2>/dev/null)" ||
        die "Could not inspect controller firewall rules."
      ;;
    ssl-certificate)
      COMPUTE_INVENTORY_JSON="$(gcloud compute ssl-certificates list --global \
        --project="${PROJECT_ID}" --format=json 2>/dev/null)" ||
        die "Could not inspect controller SSL certificates."
      ;;
    network-endpoint-group)
      COMPUTE_INVENTORY_JSON="$(gcloud compute network-endpoint-groups list \
        --project="${PROJECT_ID}" --format=json 2>/dev/null)" ||
        die "Could not inspect controller network endpoint groups."
      ;;
    *) die "Internal controller-resource kind error: ${resource_kind}" ;;
  esac
  jq -e 'type == "array"' <<<"${COMPUTE_INVENTORY_JSON}" >/dev/null ||
    die "Controller resource inventory for ${resource_kind} is malformed."
}

lookup_compute_resource() {
  local resource_kind="$1"
  local resource_location="$2"
  local resource_name="$3"
  local resource_count

  LOOKUP_RESOURCE_JSON=""
  load_compute_inventory "${resource_kind}"
  if [[ "${resource_kind}" == "network-endpoint-group" ]]; then
    [[ "${resource_location}" =~ ^[a-z]([a-z0-9-]{0,61}[a-z0-9])?$ ]] ||
      die "Invalid zonal network endpoint group location in persisted inventory."
    resource_count="$(jq -er --arg name "${resource_name}" --arg zone "${resource_location}" '
      [.[] | select(
        .name == $name and
        ((.zone // "") | split("/") | last) == $zone
      )] | length
    ' <<<"${COMPUTE_INVENTORY_JSON}")"
    if [[ "${resource_count}" == "1" ]]; then
      LOOKUP_RESOURCE_JSON="$(jq -ec --arg name "${resource_name}" --arg zone "${resource_location}" '
        [.[] | select(
          .name == $name and
          ((.zone // "") | split("/") | last) == $zone
        )][0]
      ' <<<"${COMPUTE_INVENTORY_JSON}")"
    fi
  else
    [[ "${resource_location}" == "global" ]] ||
      die "Non-zonal controller resource has an invalid persisted location."
    resource_count="$(jq -er --arg name "${resource_name}" \
      '[.[] | select(.name == $name)] | length' <<<"${COMPUTE_INVENTORY_JSON}")"
    if [[ "${resource_count}" == "1" ]]; then
      LOOKUP_RESOURCE_JSON="$(jq -ec --arg name "${resource_name}" \
        '[.[] | select(.name == $name)][0]' <<<"${COMPUTE_INVENTORY_JSON}")"
    fi
  fi
  [[ "${resource_count}" == "0" || "${resource_count}" == "1" ]] ||
    die "Controller resource lookup for ${resource_kind}/${resource_name} returned an ambiguous result."
  [[ "${resource_count}" == "1" ]]
}

capture_controller_inventory() {
  local mci_json="$1"
  local raw_inventory="$2"
  local resolved_inventory="$3"
  local resource_kind
  local resource_scope
  local resource_location
  local resource_name
  local http_exists
  local https_exists
  local controller_tls_secret_count

  install -m 0600 /dev/null "${raw_inventory}"
  install -m 0600 /dev/null "${resolved_inventory}"
  append_status_inventory "${mci_json}" forwarding-rule \
    '.status.CloudResources.ForwardingRules // .status.CloudResources.forwardingRules // .status.cloudResources.ForwardingRules // .status.cloudResources.forwardingRules' "${raw_inventory}"
  append_status_inventory "${mci_json}" target-proxy \
    '.status.CloudResources.TargetProxies // .status.CloudResources.targetProxies // .status.cloudResources.TargetProxies // .status.cloudResources.targetProxies' "${raw_inventory}"
  append_status_inventory "${mci_json}" url-map \
    '.status.CloudResources.UrlMap // .status.CloudResources.urlMap // .status.CloudResources.UrlMaps // .status.CloudResources.urlMaps // .status.cloudResources.UrlMap // .status.cloudResources.urlMap // .status.cloudResources.UrlMaps // .status.cloudResources.urlMaps' "${raw_inventory}"
  append_status_inventory "${mci_json}" health-check \
    '.status.CloudResources.HealthChecks // .status.CloudResources.healthChecks // .status.cloudResources.HealthChecks // .status.cloudResources.healthChecks' "${raw_inventory}"
  append_status_inventory "${mci_json}" backend-service \
    '.status.CloudResources.BackendServices // .status.CloudResources.backendServices // .status.cloudResources.BackendServices // .status.cloudResources.backendServices' "${raw_inventory}"
  append_status_inventory "${mci_json}" firewall-rule \
    '.status.CloudResources.Firewalls // .status.CloudResources.firewalls // .status.CloudResources.FirewallRules // .status.CloudResources.firewallRules // .status.cloudResources.Firewalls // .status.cloudResources.firewalls // .status.cloudResources.FirewallRules // .status.cloudResources.firewallRules' "${raw_inventory}"

  # Certificates referenced by networking.gke.io/pre-shared-certs are owned by
  # Terraform in this repository. Only inventory a certificate when the MCI
  # spec asks the controller to create one from a Kubernetes TLS Secret.
  controller_tls_secret_count="$(jq -er \
    '[.spec.template.spec.tls[]? | select(.secretName | type == "string" and length > 0)] | length' \
    <<<"${mci_json}")"
  if ((controller_tls_secret_count > 0)); then
    append_status_inventory "${mci_json}" ssl-certificate \
      '.status.CloudResources.SSLCertificates // .status.CloudResources.SslCertificates // .status.CloudResources.sslCertificates // .status.CloudResources.Certificates // .status.CloudResources.certificates // .status.cloudResources.SSLCertificates // .status.cloudResources.SslCertificates // .status.cloudResources.sslCertificates // .status.cloudResources.Certificates // .status.cloudResources.certificates' "${raw_inventory}"
  fi

  while IFS=$'\t' read -r resource_kind resource_scope resource_location resource_name; do
    if [[ "${resource_kind}" != "target-proxy" ]]; then
      printf '%s\t%s\t%s\t%s\n' \
        "${resource_kind}" "${resource_scope}" "${resource_location}" "${resource_name}" >>"${resolved_inventory}"
      continue
    fi
    http_exists=false
    https_exists=false
    if lookup_compute_resource target-http-proxy global "${resource_name}"; then
      http_exists=true
    fi
    if lookup_compute_resource target-https-proxy global "${resource_name}"; then
      https_exists=true
    fi
    if [[ "${http_exists}" == "true" ]]; then
      printf 'target-http-proxy\tglobal\tglobal\t%s\n' "${resource_name}" >>"${resolved_inventory}"
    fi
    if [[ "${https_exists}" == "true" ]]; then
      printf 'target-https-proxy\tglobal\tglobal\t%s\n' "${resource_name}" >>"${resolved_inventory}"
    fi
    [[ "${http_exists}:${https_exists}" != "false:false" ]] ||
      die "A controller target proxy from MultiClusterIngress status is absent in both Compute proxy kinds."
  done <"${raw_inventory}"
  [[ -s "${resolved_inventory}" ]] || die "Controller resource inventory is empty."
}

NEG_ZONE=""
NEG_NAME=""

normalize_neg_reference() {
  local group_reference="$1"
  local reference_project

  group_reference="${group_reference%%\?*}"
  group_reference="${group_reference%/}"
  if [[ "${group_reference}" =~ ^https://(www\.googleapis\.com|compute\.googleapis\.com)/compute/(v1|beta)/projects/([^/]+)/zones/([^/]+)/networkEndpointGroups/([^/]+)$ ]]; then
    reference_project="${BASH_REMATCH[3]}"
    NEG_ZONE="${BASH_REMATCH[4]}"
    NEG_NAME="${BASH_REMATCH[5]}"
  else
    die "A preflighted backend service contains a non-zonal or malformed NEG reference."
  fi
  [[ "${reference_project}" == "${PROJECT_ID}" ]] ||
    die "A controller backend service references a NEG in a different project."
  [[ "${NEG_ZONE}" =~ ^[a-z]([a-z0-9-]{0,61}[a-z0-9])?$ ]] ||
    die "A controller backend service contains an invalid NEG zone."
  [[ "${NEG_NAME}" =~ ^[a-z]([a-z0-9-]{0,61}[a-z0-9])?$ ]] ||
    die "A controller backend service contains an invalid NEG name."
}

append_backend_negs() {
  local source_inventory="$1"
  local enriched_inventory="$2"
  local resource_kind
  local resource_scope
  local resource_location
  local resource_name
  local backend_groups
  local group_reference
  local group_count

  install -m 0600 /dev/null "${enriched_inventory}"
  while IFS=$'\t' read -r resource_kind resource_scope resource_location resource_name; do
    printf '%s\t%s\t%s\t%s\n' \
      "${resource_kind}" "${resource_scope}" "${resource_location}" "${resource_name}" >>"${enriched_inventory}"
    [[ "${resource_kind}" == "backend-service" ]] || continue
    lookup_compute_resource backend-service global "${resource_name}" ||
      die "Controller backend service ${resource_name} is absent before preflight."
    backend_groups="$(jq -er '
      [.backends[]?.group | select(type == "string" and length > 0)] |
      if length > 0 then .[] else error("backend service has no NEG groups") end
    ' <<<"${LOOKUP_RESOURCE_JSON}")" ||
      die "Controller backend service ${resource_name} does not expose zonal NEG backends."
    group_count=0
    while IFS= read -r group_reference; do
      [[ -n "${group_reference}" ]] || continue
      normalize_neg_reference "${group_reference}"
      printf 'network-endpoint-group\tzonal\t%s\t%s\n' \
        "${NEG_ZONE}" "${NEG_NAME}" >>"${enriched_inventory}"
      group_count=$((group_count + 1))
    done <<<"${backend_groups}"
    ((group_count > 0)) ||
      die "Controller backend service ${resource_name} has no usable zonal NEG references."
  done <"${source_inventory}"
}

deduplicate_inventory() {
  local source_inventory="$1"
  local destination_inventory="$2"
  local resource_kind
  local resource_scope
  local resource_location
  local resource_name
  local inventory_key
  declare -A seen_inventory=()

  install -m 0600 /dev/null "${destination_inventory}"
  while IFS=$'\t' read -r resource_kind resource_scope resource_location resource_name; do
    [[ -n "${resource_kind}" && -n "${resource_scope}" &&
      -n "${resource_location}" && -n "${resource_name}" ]] ||
      die "Controller resource inventory contains an incomplete record."
    inventory_key="${resource_kind}|${resource_scope}|${resource_location}|${resource_name}"
    if [[ -z "${seen_inventory[${inventory_key}]+present}" ]]; then
      seen_inventory["${inventory_key}"]=true
      printf '%s\t%s\t%s\t%s\n' \
        "${resource_kind}" "${resource_scope}" "${resource_location}" "${resource_name}" >>"${destination_inventory}"
    fi
  done <"${source_inventory}"
  [[ -s "${destination_inventory}" ]] || die "Resolved controller resource inventory is empty."
}

preflight_inventory() {
  local inventory_file="$1"
  local resource_kind
  local resource_scope
  local resource_location
  local resource_name

  while IFS=$'\t' read -r resource_kind resource_scope resource_location resource_name; do
    if [[ "${resource_kind}" == "network-endpoint-group" ]]; then
      [[ "${resource_scope}" == "zonal" ]] || die "A NEG inventory record is not zonal."
    else
      [[ "${resource_scope}:${resource_location}" == "global:global" ]] ||
        die "A controller global-resource inventory record has an invalid scope."
    fi
    lookup_compute_resource "${resource_kind}" "${resource_location}" "${resource_name}" ||
      die "Controller resource ${resource_kind}/${resource_name} is not uniquely present before Kubernetes deletion."
  done <"${inventory_file}"
}

validate_persisted_inventory_contents() {
  local inventory_file="$1"

  jq -e --arg project "${PROJECT_ID}" --arg bucket "${TF_STATE_BUCKET}" \
    --arg namespace "${MCI_NAMESPACE}" --arg name "${MCI_NAME}" '
    .resources as $resources |
    (keys | sort) == ["captured_at_utc", "mci", "preflighted", "project_id", "resources", "state_bucket", "version"] and
    .version == 1 and
    .preflighted == true and
    .project_id == $project and
    .state_bucket == $bucket and
    (.captured_at_utc | type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")) and
    (.mci | type == "object") and
    (.mci | keys | sort) == ["name", "namespace", "uid"] and
    .mci.namespace == $namespace and
    .mci.name == $name and
    (.mci.uid | type == "string" and test("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")) and
    ($resources | type == "array" and length > 0) and
    [
      "forwarding-rule",
      "target-http-proxy",
      "target-https-proxy",
      "url-map",
      "health-check",
      "backend-service",
      "firewall-rule",
      "ssl-certificate",
      "network-endpoint-group"
    ] as $allowed_kinds |
    all($resources[];
      .kind as $kind |
      (keys | sort) == ["kind", "location", "name", "scope"] and
      ($allowed_kinds | index($kind)) != null and
      (.name | type == "string" and test("^[a-z]([a-z0-9-]{0,61}[a-z0-9])?$")) and
      (if $kind == "network-endpoint-group" then
        .scope == "zonal" and
        (.location | type == "string" and test("^[a-z]([a-z0-9-]{0,61}[a-z0-9])?$"))
      else
        .scope == "global" and .location == "global"
      end)
    ) and
    ($resources | unique_by([.kind, .scope, .location, .name]) | length) == ($resources | length) and
    all([
      "forwarding-rule",
      "url-map",
      "health-check",
      "backend-service",
      "firewall-rule",
      "network-endpoint-group"
    ][]; . as $required_kind | any($resources[]; .kind == $required_kind)) and
    any($resources[]; .kind == "target-http-proxy" or .kind == "target-https-proxy")
  ' "${inventory_file}" >/dev/null ||
    die "Persisted teardown inventory is invalid or does not match this project/MultiClusterIngress; recover it manually before teardown."
}

ensure_inventory_directory() {
  if [[ -e "${INVENTORY_DIR}" || -L "${INVENTORY_DIR}" ]]; then
    [[ -d "${INVENTORY_DIR}" && ! -L "${INVENTORY_DIR}" ]] ||
      die "Ignored .generated path is not a regular directory; refusing inventory persistence."
  else
    install -d -m 0700 "${INVENTORY_DIR}"
  fi
}

FILE_DIGEST=""
INVENTORY_IDENTITY_DIGEST=""

calculate_file_digest() {
  local source_file="$1"

  read -r FILE_DIGEST _ < <(sha256sum "${source_file}")
  [[ "${FILE_DIGEST}" =~ ^[a-f0-9]{64}$ ]] || die "Could not calculate file digest."
}

calculate_inventory_identity_digest() {
  local source_file="$1"
  local canonical_inventory

  canonical_inventory="$(jq -ceS '{
      version,
      project_id,
      state_bucket,
      mci,
      resources: (.resources | sort_by(.kind, .scope, .location, .name))
    }' "${source_file}")" ||
    die "Could not canonicalize the recovery inventory identity."
  read -r INVENTORY_IDENTITY_DIGEST _ < <(sha256sum <<<"${canonical_inventory}")
  [[ "${INVENTORY_IDENTITY_DIGEST}" =~ ^[a-f0-9]{64}$ ]] ||
    die "Could not calculate the canonical recovery inventory identity digest."
}

inspect_local_inventory() {
  LOCAL_INVENTORY_PRESENT="false"
  if [[ ! -e "${INVENTORY_FILE}" && ! -L "${INVENTORY_FILE}" ]]; then
    return 0
  fi
  [[ -f "${INVENTORY_FILE}" && ! -L "${INVENTORY_FILE}" &&
    -r "${INVENTORY_FILE}" && -O "${INVENTORY_FILE}" ]] ||
    die "Local teardown recovery inventory has a suspicious file type or owner; recover it manually before teardown."
  [[ "$(stat -c '%a' "${INVENTORY_FILE}")" == "600" ]] ||
    die "Local teardown recovery inventory must have mode 0600."
  validate_persisted_inventory_contents "${INVENTORY_FILE}"
  LOCAL_INVENTORY_PRESENT="true"
}

discover_remote_inventory() {
  local destination_file="$1"
  local discovered_generation

  REMOTE_INVENTORY_PRESENT="false"
  REMOTE_INVENTORY_GENERATION=""
  install -m 0600 /dev/null "${destination_file}"
  inspect_versioned_object "${REMOTE_INVENTORY_OBJECT}" "controller recovery inventory object"
  case "${DISCOVERED_STATE_STATUS}" in
    present) discovered_generation="${DISCOVERED_STATE_GENERATION}" ;;
    historical-only|absent) return 0 ;;
    *) die "Internal durable teardown recovery object classification error." ;;
  esac
  refresh_adc_token
  if ! gcloud --access-token-file="${adc_token_file}" storage cat \
    "${REMOTE_INVENTORY_URI}" >"${destination_file}" 2>/dev/null; then
    die "Durable teardown recovery inventory exists but could not be read."
  fi
  chmod 0600 "${destination_file}"
  validate_persisted_inventory_contents "${destination_file}"
  require_versioned_object_generation "${REMOTE_INVENTORY_OBJECT}" \
    "controller recovery inventory object" "${discovered_generation}"
  REMOTE_INVENTORY_PRESENT="true"
  REMOTE_INVENTORY_GENERATION="${discovered_generation}"
}

create_local_inventory_without_replacement() {
  local source_file="$1"
  local source_digest
  local installed_digest

  ensure_inventory_directory
  calculate_file_digest "${source_file}"
  source_digest="${FILE_DIGEST}"
  inventory_candidate="$(mktemp "${INVENTORY_DIR}/teardown-controller-inventory.XXXXXX")"
  install -m 0600 "${source_file}" "${inventory_candidate}"
  validate_persisted_inventory_contents "${inventory_candidate}"
  calculate_file_digest "${inventory_candidate}"
  installed_digest="${FILE_DIGEST}"
  [[ "${installed_digest}" == "${source_digest}" ]] ||
    die "Preparing the local teardown inventory changed its content."
  if ! ln -- "${inventory_candidate}" "${INVENTORY_FILE}"; then
    die "Local teardown recovery inventory appeared concurrently; no inventory was replaced. Reconcile the local and durable copies manually before retrying."
  fi
  rm -f -- "${inventory_candidate}"
  inventory_candidate=""
  inspect_local_inventory
  calculate_file_digest "${INVENTORY_FILE}"
  [[ "${FILE_DIGEST}" == "${source_digest}" ]] ||
    die "The newly persisted local teardown inventory differs from its validated source."
}

reconcile_recovery_inventories_at_startup() {
  local local_digest
  local remote_digest

  inspect_local_inventory
  discover_remote_inventory "${remote_inventory_snapshot}"
  if [[ "${LOCAL_INVENTORY_PRESENT}:${REMOTE_INVENTORY_PRESENT}" == "true:true" ]]; then
    calculate_file_digest "${INVENTORY_FILE}"
    local_digest="${FILE_DIGEST}"
    calculate_file_digest "${remote_inventory_snapshot}"
    remote_digest="${FILE_DIGEST}"
    [[ "${local_digest}" == "${remote_digest}" ]] ||
      die "Local and durable teardown recovery inventories conflict. Neither was replaced; manually establish the authoritative exact inventory before retrying."
  elif [[ "${LOCAL_INVENTORY_PRESENT}:${REMOTE_INVENTORY_PRESENT}" == "false:true" ]]; then
    create_local_inventory_without_replacement "${remote_inventory_snapshot}"
  fi
}

require_matching_local_and_durable_inventory() {
  local local_digest
  local remote_digest

  inspect_local_inventory
  [[ "${LOCAL_INVENTORY_PRESENT}" == "true" ]] ||
    die "Validated durable recovery requires its exact local counterpart."
  discover_remote_inventory "${remote_inventory_snapshot}"
  [[ "${REMOTE_INVENTORY_PRESENT}" == "true" ]] ||
    die "The exact durable teardown recovery object is absent; refusing Kubernetes or Terraform mutation."
  calculate_file_digest "${INVENTORY_FILE}"
  local_digest="${FILE_DIGEST}"
  calculate_file_digest "${remote_inventory_snapshot}"
  remote_digest="${FILE_DIGEST}"
  [[ "${local_digest}" == "${remote_digest}" ]] ||
    die "Local and durable teardown recovery inventories changed or conflict. Neither was replaced; manually establish the authoritative exact inventory before retrying."
}

create_durable_inventory_without_replacement() {
  local local_digest
  local remote_digest

  inspect_local_inventory
  [[ "${LOCAL_INVENTORY_PRESENT}" == "true" ]] ||
    die "Internal error: no validated local inventory is available for durable persistence."
  [[ "${REMOTE_INVENTORY_PRESENT}" == "false" ]] ||
    die "Refusing to replace an existing durable teardown recovery inventory."
  calculate_file_digest "${INVENTORY_FILE}"
  local_digest="${FILE_DIGEST}"
  refresh_adc_token
  if ! gcloud --access-token-file="${adc_token_file}" storage cp \
    "${INVENTORY_FILE}" "${REMOTE_INVENTORY_URI}" \
    --if-generation-match=0 --quiet >/dev/null 2>&1; then
    die "Could not create the durable teardown recovery inventory without replacement. No Kubernetes mutation was attempted; inspect and reconcile any concurrently created object before retrying."
  fi
  discover_remote_inventory "${remote_inventory_snapshot}"
  [[ "${REMOTE_INVENTORY_PRESENT}" == "true" ]] ||
    die "Uploaded teardown recovery inventory was not discoverable; no Kubernetes mutation was attempted."
  calculate_file_digest "${remote_inventory_snapshot}"
  remote_digest="${FILE_DIGEST}"
  [[ "${remote_digest}" == "${local_digest}" ]] ||
    die "Durable teardown recovery inventory digest differs from the validated local inventory."
}

build_preflighted_inventory() {
  local inventory_tsv="$1"
  local mci_uid="$2"
  local destination_file="$3"

  install -m 0600 /dev/null "${destination_file}"
  jq -Rn --arg project "${PROJECT_ID}" --arg bucket "${TF_STATE_BUCKET}" \
    --arg namespace "${MCI_NAMESPACE}" \
    --arg name "${MCI_NAME}" --arg uid "${mci_uid}" \
    --arg captured_at "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" '
      [inputs | split("\t") |
        {kind: .[0], scope: .[1], location: .[2], name: .[3]}] |
      {
        version: 1,
        preflighted: true,
        project_id: $project,
        state_bucket: $bucket,
        captured_at_utc: $captured_at,
        mci: {namespace: $namespace, name: $name, uid: $uid},
        resources: .
      }
    ' <"${inventory_tsv}" >"${destination_file}"
  chmod 0600 "${destination_file}"
  validate_persisted_inventory_contents "${destination_file}"
}

persist_preflighted_inventory() {
  local inventory_tsv="$1"
  local mci_uid="$2"
  local live_candidate="${temporary_root}/live-controller-inventory.json"
  local existing_identity_digest
  local candidate_identity_digest

  build_preflighted_inventory "${inventory_tsv}" "${mci_uid}" "${live_candidate}"
  calculate_inventory_identity_digest "${live_candidate}"
  candidate_identity_digest="${INVENTORY_IDENTITY_DIGEST}"

  if [[ "${LOCAL_INVENTORY_PRESENT}" == "true" ]]; then
    calculate_inventory_identity_digest "${INVENTORY_FILE}"
    existing_identity_digest="${INVENTORY_IDENTITY_DIGEST}"
    [[ "${existing_identity_digest}" == "${candidate_identity_digest}" ]] ||
      die "The live MultiClusterIngress UID or exact controller resource set conflicts with the existing recovery inventory. Neither copy was replaced; manually reconcile the authoritative inventory before retrying."
    if [[ "${REMOTE_INVENTORY_PRESENT}" == "false" ]]; then
      create_durable_inventory_without_replacement
    else
      require_matching_local_and_durable_inventory
    fi
    return 0
  fi

  [[ "${REMOTE_INVENTORY_PRESENT}" == "false" ]] ||
    die "Internal error: durable recovery inventory exists without its validated local counterpart."
  create_local_inventory_without_replacement "${live_candidate}"
  create_durable_inventory_without_replacement
}

audit_persisted_inventory_access() {
  local resource_kind
  local resource_scope
  local resource_location
  local resource_name
  local present_count=0
  local absent_count=0

  while IFS=$'\t' read -r resource_kind resource_scope resource_location resource_name; do
    if lookup_compute_resource "${resource_kind}" "${resource_location}" "${resource_name}"; then
      present_count=$((present_count + 1))
    else
      absent_count=$((absent_count + 1))
    fi
  done < <(jq -r '.resources[] | [.kind, .scope, .location, .name] | @tsv' "${INVENTORY_FILE}")
  printf 'Audited durable controller inventory: %d present, %d already absent.\n' \
    "${present_count}" "${absent_count}"
}

wait_for_controller_cleanup() {
  local inventory_file="$1"
  local deadline=$((SECONDS + LOAD_BALANCER_TIMEOUT_SECONDS))
  local resource_kind
  local resource_scope
  local resource_location
  local resource_name
  local remaining_count

  while ((SECONDS < deadline)); do
    remaining_count=0
    while IFS=$'\t' read -r resource_kind resource_scope resource_location resource_name; do
      if lookup_compute_resource "${resource_kind}" "${resource_location}" "${resource_name}"; then
        remaining_count=$((remaining_count + 1))
      fi
    done < <(jq -r '.resources[] | [.kind, .scope, .location, .name] | @tsv' "${inventory_file}")
    if ((remaining_count == 0)); then
      printf '%s\n' 'All recorded controller-managed resources are deleted or were already absent.'
      return 0
    fi
    sleep 20
  done
  die "${remaining_count} inventoried controller-managed cloud resources remain after the bounded timeout."
}

CLUSTER_PRESENT="false"

inspect_cluster_existence() {
  local cluster_name="$1"
  local cluster_region="$2"
  local cluster_inventory
  local cluster_count

  CLUSTER_PRESENT="false"
  if ! cluster_inventory="$(gcloud container clusters list --location="${cluster_region}" \
    --project="${PROJECT_ID}" --format=json 2>/dev/null)"; then
    die "Could not inspect cluster ${cluster_name}; refusing to treat an access or API error as absence."
  fi
  jq -e '
    type == "array" and
    all(.[];
      type == "object" and
      (.name | type) == "string" and
      ((.location // .zone // null) | type) == "string"
    )
  ' <<<"${cluster_inventory}" >/dev/null ||
    die "Cluster inventory response is malformed; refusing to treat it as absence."
  cluster_count="$(jq -er --arg name "${cluster_name}" --arg location "${cluster_region}" '
    [.[] | select(.name == $name and ((.location // .zone // "") == $location))] | length
  ' <<<"${cluster_inventory}")" || die "Cluster inventory response could not be classified."
  [[ "${cluster_count}" == "0" || "${cluster_count}" == "1" ]] ||
    die "Cluster discovery for ${cluster_name} returned an ambiguous result."
  if [[ "${cluster_count}" == "1" ]]; then
    CLUSTER_PRESENT="true"
  fi
}

DISCOVERED_STATE_STATUS=""
DISCOVERED_STATE_GENERATION=""
DISCOVERED_STATE_HISTORICAL_COUNT="0"
DISCOVERED_STATE_SOFT_DELETED_COUNT="0"
DISCOVERED_STATE_GENERATIONS_JSON="[]"
RECOVERY_INVENTORY_HISTORY_PRESENT="false"
COMPLETION_MARKER_HISTORY_PRESENT="false"

# A normal versioned listing excludes soft-deleted objects. Classify both views and
# retain only the caller's exact object name; any cross-view duplicate is a race.
inspect_versioned_object() {
  local object_name="$1"
  local description="$2"
  local bucket_objects_uri="gs://${TF_STATE_BUCKET}/**"
  local versions_json
  local matching_versions
  local soft_deleted_json
  local matching_soft_deleted
  local live_count
  local noncurrent_count
  local duplicate_count

  DISCOVERED_STATE_STATUS=""
  DISCOVERED_STATE_GENERATION=""
  DISCOVERED_STATE_HISTORICAL_COUNT="0"
  DISCOVERED_STATE_SOFT_DELETED_COUNT="0"
  DISCOVERED_STATE_GENERATIONS_JSON="[]"

  refresh_adc_token
  if ! versions_json="$(gcloud --access-token-file="${adc_token_file}" storage ls \
    --all-versions --json "${bucket_objects_uri}" 2>/dev/null)"; then
    die "Could not authoritatively list live and noncurrent ${description} generations; refusing to treat an access or API error as absence."
  fi
  jq -e 'type == "array"' <<<"${versions_json}" >/dev/null ||
    die "Live/noncurrent ${description} discovery returned malformed JSON."
  jq -e '
    all(.[];
      .type == "cloud_object" and
      (.metadata | type) == "object" and
      (.metadata.name | type == "string" and length > 0) and
      (.metadata.generation | type == "string" and test("^[1-9][0-9]*$")) and
      ((.metadata | has("timeDeleted") | not) or
       (.metadata.timeDeleted | type == "string" and length > 0))
    )
  ' <<<"${versions_json}" >/dev/null ||
    die "Live/noncurrent state-bucket object metadata is malformed; refusing to infer exact-object absence."
  matching_versions="$(jq -cer --arg object "${object_name}" \
    '[.[] | select(.metadata.name == $object)]' <<<"${versions_json}")" ||
    die "Could not select the exact live/noncurrent ${description} identity."

  refresh_adc_token
  if ! soft_deleted_json="$(gcloud --access-token-file="${adc_token_file}" storage ls \
    --soft-deleted --exhaustive --json "${bucket_objects_uri}" 2>/dev/null)"; then
    die "Could not authoritatively list soft-deleted ${description} generations; refusing to treat an access or API error as absence."
  fi
  jq -e 'type == "array"' <<<"${soft_deleted_json}" >/dev/null ||
    die "Soft-deleted ${description} discovery returned malformed JSON."
  jq -e '
    all(.[];
      .type == "cloud_object" and
      (.metadata | type) == "object" and
      (.metadata.name | type == "string" and length > 0) and
      (.metadata.generation | type == "string" and test("^[1-9][0-9]*$")) and
      (.metadata.softDeleteTime | type == "string" and length > 0) and
      (.metadata.hardDeleteTime | type == "string" and length > 0)
    )
  ' <<<"${soft_deleted_json}" >/dev/null ||
    die "Soft-deleted state-bucket object metadata is malformed; refusing to infer exact-object absence."
  matching_soft_deleted="$(jq -cer --arg object "${object_name}" \
    '[.[] | select(.metadata.name == $object)]' <<<"${soft_deleted_json}")" ||
    die "Could not select the exact soft-deleted ${description} identity."

  duplicate_count="$(jq -ner --argjson ordinary "${matching_versions}" \
    --argjson soft "${matching_soft_deleted}" '
      [($ordinary + $soft)[] | .metadata.generation] |
      (length - (unique | length))
    ')" || die "Could not reconcile ${description} generation identities."
  [[ "${duplicate_count}" == "0" ]] ||
    die "${description^} discovery returned duplicate or concurrently transitioning generation identities."
  DISCOVERED_STATE_GENERATIONS_JSON="$(jq -cner --argjson ordinary "${matching_versions}" \
    --argjson soft "${matching_soft_deleted}" '
      [($ordinary + $soft)[] | .metadata.generation] | unique
    ')" || die "Could not retain the exact ${description} generation identities."
  live_count="$(jq -er '[.[] | select((.metadata | has("timeDeleted")) | not)] | length' \
    <<<"${matching_versions}")"
  noncurrent_count="$(jq -er '[.[] | select(.metadata | has("timeDeleted"))] | length' \
    <<<"${matching_versions}")"
  DISCOVERED_STATE_SOFT_DELETED_COUNT="$(jq -er 'length' <<<"${matching_soft_deleted}")"
  DISCOVERED_STATE_HISTORICAL_COUNT="$((noncurrent_count + DISCOVERED_STATE_SOFT_DELETED_COUNT))"
  [[ "${live_count}" == "0" || "${live_count}" == "1" ]] ||
    die "Versioned ${description} discovery returned more than one live generation."

  if [[ "${live_count}" == "1" ]]; then
    DISCOVERED_STATE_STATUS="present"
    DISCOVERED_STATE_GENERATION="$(jq -er '
      [.[] | select((.metadata | has("timeDeleted")) | not)][0].metadata.generation
    ' <<<"${matching_versions}")"
  elif ((DISCOVERED_STATE_HISTORICAL_COUNT > 0)); then
    DISCOVERED_STATE_STATUS="historical-only"
  else
    DISCOVERED_STATE_STATUS="absent"
  fi
}

require_versioned_object_generation() {
  local object_name="$1"
  local description="$2"
  local expected_generation="$3"

  inspect_versioned_object "${object_name}" "${description}"
  [[ "${DISCOVERED_STATE_STATUS}" == "present" ]] ||
    die "The exact ${description} became unavailable or historical-only during inspection."
  [[ "${DISCOVERED_STATE_GENERATION}" == "${expected_generation}" ]] ||
    die "The exact ${description} changed concurrently during inspection."
}

inspect_stage_state_object() {
  local stage="$1"

  case "${stage}" in
    platform|foundation) ;;
    bootstrap|*) die "Refusing state discovery for Terraform root: ${stage}" ;;
  esac
  inspect_versioned_object "${stage}/default.tfstate" "${stage} state object"
}

inspect_recovery_inventory_history() {
  inspect_versioned_object "${REMOTE_INVENTORY_OBJECT}" "controller recovery inventory object"
  case "${DISCOVERED_STATE_STATUS}" in
    absent) RECOVERY_INVENTORY_HISTORY_PRESENT="false" ;;
    present|historical-only) RECOVERY_INVENTORY_HISTORY_PRESENT="true" ;;
    *) die "Internal controller recovery inventory history classification error." ;;
  esac
}

inspect_completion_marker_history() {
  inspect_versioned_object "${COMPLETION_MARKER_OBJECT}" "teardown completion marker object"
  case "${DISCOVERED_STATE_STATUS}" in
    absent) COMPLETION_MARKER_HISTORY_PRESENT="false" ;;
    present|historical-only) COMPLETION_MARKER_HISTORY_PRESENT="true" ;;
    *) die "Internal teardown completion marker history classification error." ;;
  esac
}

require_durable_inventory() {
  [[ "${REMOTE_INVENTORY_PRESENT}" == "true" ]] ||
    die "The primary cluster or MultiClusterIngress is absent without validated durable recovery inventory at ${REMOTE_INVENTORY_URI}. Restore the cluster/MCI or recover and upload the exact inventory before teardown."
  require_matching_local_and_durable_inventory
}

remove_recovery_inventories() {
  local expected_generation

  [[ "${REMOTE_INVENTORY_PRESENT}" == "true" ]] ||
    die "Durable recovery inventory unexpectedly became unavailable before final cleanup."
  require_matching_local_and_durable_inventory
  expected_generation="${REMOTE_INVENTORY_GENERATION}"
  refresh_adc_token
  # Remove the cache before the conditional remote delete. An ambiguous remote
  # result then leaves either a durable copy that can restore it or the active marker.
  rm -f -- "${INVENTORY_FILE}"
  if ! gcloud --access-token-file="${adc_token_file}" storage rm \
    "${REMOTE_INVENTORY_URI}" --if-generation-match="${expected_generation}" \
    --quiet >/dev/null; then
    die "Could not confirm generation-bound durable recovery inventory removal after its local cache was removed. Retry: a retained live generation will restore the cache; an already-completed deletion will use the completion-bound path."
  fi
  discover_remote_inventory "${remote_inventory_snapshot}"
  [[ "${REMOTE_INVENTORY_PRESENT}" == "false" ]] ||
    die "A new live controller recovery inventory appeared after generation-bound removal; teardown completion was not reported."
}

prepare_teardown_cleanup() {
inspect_stage_state_object platform
platform_state_status="${DISCOVERED_STATE_STATUS}"
inspect_stage_state_object foundation
foundation_state_status="${DISCOVERED_STATE_STATUS}"

[[ "${platform_state_status}" != "historical-only" ]] ||
  die "Platform Terraform state has only noncurrent or soft-deleted generations. Treat this as lost state and recover the exact live state before teardown."
case "${foundation_state_status}" in
  present) ;;
  historical-only)
    die "Foundation Terraform state has only noncurrent or soft-deleted generations. Recover the exact live state before teardown."
    ;;
  absent)
    die "Foundation Terraform state was never created or its complete history is unavailable; this teardown supports only a present foundation state."
    ;;
  *) die "Internal foundation state classification error." ;;
esac
if [[ "${platform_state_status}" == "absent" ]]; then
  inspect_recovery_inventory_history
  inspect_completion_marker_history
fi

reconcile_recovery_inventories_at_startup
if [[ "${LOCAL_INVENTORY_PRESENT}:${REMOTE_INVENTORY_PRESENT}" == "true:true" ]]; then
  printf '%s\n' 'Validated matching local and durable teardown recovery inventories before cluster discovery.'
elif [[ "${LOCAL_INVENTORY_PRESENT}" == "true" ]]; then
  printf '%s\n' 'Validated local-only teardown recovery inventory; a matching live MCI is required before durable creation.'
else
  printf '%s\n' 'No teardown recovery inventory exists; a live MCI must be fully preflighted before mutation.'
fi

inspect_cluster_existence "${PRIMARY_CLUSTER}" "${PRIMARY_REGION}"
primary_cluster_present="${CLUSTER_PRESENT}"
inspect_cluster_existence "${SECONDARY_CLUSTER}" "${SECONDARY_REGION}"
secondary_cluster_present="${CLUSTER_PRESENT}"

platform_never_created="false"
platform_completed_empty="false"
if [[ "${platform_state_status}" == "absent" ]]; then
  if [[ "${primary_cluster_present}:${secondary_cluster_present}" != "false:false" ||
    "${LOCAL_INVENTORY_PRESENT}:${REMOTE_INVENTORY_PRESENT}" != "false:false" ||
    "${RECOVERY_INVENTORY_HISTORY_PRESENT}:${COMPLETION_MARKER_HISTORY_PRESENT}" != "false:false" ]]; then
    die "Platform state is absent but cluster, controller-recovery, or teardown-completion evidence exists. Refusing to classify possible lost state as a never-created platform."
  fi
  platform_never_created="true"
  printf '%s\n' 'Platform state, controller inventory, and completion marker have no live, noncurrent, or soft-deleted generation, and both supported clusters are absent; using the genuinely-never-created foundation-only path.'
elif [[ "${primary_cluster_present}:${secondary_cluster_present}" == "false:false" &&
  "${LOCAL_INVENTORY_PRESENT}:${REMOTE_INVENTORY_PRESENT}" == "false:false" ]]; then
  authorize_completed_empty_platform
  if [[ "${COMPLETION_SHORTCUT_AUTHORIZED}" == "true" ]]; then
    platform_completed_empty="true"
    printf '%s\n' 'The exact live platform state is valid, empty, generation-stable, and bound to a live teardown completion marker; using the completed-platform foundation-only recovery path.'
  fi
fi

dns_primary=""
dns_secondary=""
mci_present="false"
if [[ "${platform_never_created}" == "true" ]]; then
  printf '%s\n' 'Skipping Kubernetes and controller cleanup because the platform stage is proven genuinely never-created.'
elif [[ "${platform_completed_empty}" == "true" ]]; then
  printf '%s\n' 'Skipping Kubernetes and controller cleanup because the exact empty platform state is bound to a prior completed teardown and both supported clusters remain absent.'
else
  if [[ "${primary_cluster_present}" == "true" ]]; then
    dns_primary="${temporary_root}/dns-primary.kubeconfig"
    get_dns_credentials "${PRIMARY_CLUSTER}" "${PRIMARY_REGION}" "${dns_primary}"
    mci_json="$(KUBECONFIG="${dns_primary}" kubectl -n "${MCI_NAMESPACE}" get \
      "multiclusteringress.networking.gke.io/${MCI_NAME}" --ignore-not-found -o json)" ||
      die "MultiClusterIngress lookup failed; refusing Kubernetes or Terraform mutation."
    if [[ -n "${mci_json}" ]]; then
      mci_present="true"
      mci_uid="$(jq -er --arg namespace "${MCI_NAMESPACE}" --arg name "${MCI_NAME}" '
        select(.metadata.namespace == $namespace and .metadata.name == $name) |
        .metadata.uid |
        select(type == "string" and test("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"))
      ' <<<"${mci_json}")" || die "MultiClusterIngress identity is malformed."
      raw_inventory="${temporary_root}/mci-controller-inventory.raw.tsv"
      resolved_inventory="${temporary_root}/mci-controller-inventory.resolved.tsv"
      enriched_inventory="${temporary_root}/mci-controller-inventory.enriched.tsv"
      controller_inventory="${temporary_root}/mci-controller-inventory.final.tsv"
      capture_controller_inventory "${mci_json}" "${raw_inventory}" "${resolved_inventory}"
      append_backend_negs "${resolved_inventory}" "${enriched_inventory}"
      deduplicate_inventory "${enriched_inventory}" "${controller_inventory}"
      preflight_inventory "${controller_inventory}"
      persist_preflighted_inventory "${controller_inventory}" "${mci_uid}"
      printf '%s\n' 'Validated an exact, conflict-free local and durable controller inventory before Kubernetes deletion.'
    else
      require_durable_inventory
      printf '%s\n' 'MultiClusterIngress is already absent; resuming from durable recovery inventory.'
    fi
  else
    require_durable_inventory
    printf '%s\n' 'Primary cluster is already absent; resuming from durable recovery inventory.'
  fi

  validate_controller_inventory_history_chain
  printf '%s\n' 'Validated every recoverable controller-inventory generation against the prior completion marker and current live inventory before mutation.'
  audit_persisted_inventory_access

  if [[ "${secondary_cluster_present}" == "true" ]]; then
    dns_secondary="${temporary_root}/dns-secondary.kubeconfig"
    get_dns_credentials "${SECONDARY_CLUSTER}" "${SECONDARY_REGION}" "${dns_secondary}"
  fi

  if [[ "${primary_cluster_present}" == "true" ]]; then
    printf '%s\n' 'Deleting applicable config-cluster resources.'
    if [[ "${mci_present}" == "true" ]]; then
      KUBECONFIG="${dns_primary}" kubectl -n "${MCI_NAMESPACE}" delete \
        "multiclusteringress.networking.gke.io/${MCI_NAME}" \
        --wait=true --timeout=20m
    fi
    KUBECONFIG="${dns_primary}" kubectl -n "${MCI_NAMESPACE}" delete \
      multiclusterservice.networking.gke.io/app-a-mcs \
      multiclusterservice.networking.gke.io/app-b-mcs \
      --ignore-not-found --wait=true --timeout=20m
    KUBECONFIG="${dns_primary}" kubectl -n "${MCI_NAMESPACE}" delete \
      frontendconfig.networking.gke.io/assessment-https \
      backendconfig.cloud.google.com/app-a-backend \
      backendconfig.cloud.google.com/app-b-backend \
      --ignore-not-found --wait=true --timeout=10m
  else
    printf '%s\n' 'Primary cluster is absent; its Kubernetes resources are already removed.'
  fi

  wait_for_controller_cleanup "${INVENTORY_FILE}"

  printf '%s\n' 'Deleting regional workload, namespace, and access resources where clusters remain.'
  if [[ "${secondary_cluster_present}" == "true" ]]; then
    KUBECONFIG="${dns_secondary}" kubectl delete namespace assessment observability \
      --ignore-not-found --wait=true --timeout=10m
    KUBECONFIG="${dns_secondary}" kubectl delete \
      clusterrole/assessment-deployer-gateway-impersonation \
      clusterrolebinding/assessment-deployer-gateway-impersonation \
      --ignore-not-found --wait=true --timeout=5m
  else
    printf '%s\n' 'Secondary cluster is absent; its Kubernetes resources are already removed.'
  fi
  if [[ "${primary_cluster_present}" == "true" ]]; then
    KUBECONFIG="${dns_primary}" kubectl delete namespace assessment observability \
      --ignore-not-found --wait=true --timeout=10m
    KUBECONFIG="${dns_primary}" kubectl delete \
      clusterrole/assessment-deployer-gateway-impersonation \
      clusterrolebinding/assessment-deployer-gateway-impersonation \
      --ignore-not-found --wait=true --timeout=5m
  fi
fi

if [[ "${platform_never_created}" == "true" ]]; then
  kubernetes_cleanup_result="skipped-platform-never-created"
  multicluster_cleanup_result="skipped-platform-never-created"
elif [[ "${platform_completed_empty}" == "true" ]]; then
  kubernetes_cleanup_result="skipped-platform-completion-bound"
  multicluster_cleanup_result="skipped-platform-completion-bound"
else
  kubernetes_cleanup_result="completed-or-already-absent"
  multicluster_cleanup_result="completed-or-already-absent"
fi
}

PERSISTED_STATE_GENERATION=""
TERRAFORM_STATE_BINDING_DIGEST=""
BOUND_PLATFORM_GENERATION=""
BOUND_PLATFORM_LINEAGE=""
BOUND_PLATFORM_SERIAL=""
BOUND_PLATFORM_DIGEST=""
BOUND_FOUNDATION_GENERATION=""
BOUND_FOUNDATION_LINEAGE=""
BOUND_FOUNDATION_SERIAL=""
BOUND_FOUNDATION_DIGEST=""
VALIDATED_INVENTORY_GENERATION=""
VALIDATED_INVENTORY_GENERATIONS_JSON="[]"
VALIDATED_MARKER_REPLACEMENT_GENERATION="0"
COMPLETION_SHORTCUT_AUTHORIZED="false"

validate_terraform_state_snapshot() {
  local state_file="$1"
  local stage="$2"

  jq -e '
    type == "object" and
    .version == 4 and
    (.terraform_version | type == "string" and test("^[0-9]+\\.[0-9]+\\.[0-9]+([+-][0-9A-Za-z.-]+)?$")) and
    (.serial | type == "number" and . >= 0 and floor == .) and
    (.lineage | type == "string" and test("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")) and
    (.outputs | type == "object") and
    all(.outputs | to_entries[];
      (.key | type == "string" and length > 0) and
      (.value | type == "object") and
      (.value | ((has("sensitive") | not) or (.sensitive | type == "boolean"))) and
      (.value | has("type") and has("value"))
    ) and
    (.resources | type == "array") and
    all(.resources[];
      type == "object" and
      (.mode == "managed" or .mode == "data") and
      (.type | type == "string" and length > 0) and
      (.name | type == "string" and length > 0) and
      (.provider | type == "string" and length > 0) and
      ((has("module") | not) or (.module | type == "string" and length > 0)) and
      (.instances | type == "array") and
      all(.instances[];
        type == "object" and
        (.schema_version | type == "number" and . >= 0 and floor == .) and
        has("attributes") and
        ((.attributes | type) == "object" or (.attributes | type) == "null") and
        ((has("sensitive_attributes") | not) or (.sensitive_attributes | type == "array")) and
        ((has("private") | not) or (.private | type == "string")) and
        ((has("dependencies") | not) or
          (.dependencies | type == "array" and all(.[]; type == "string")))
      )
    )
  ' "${state_file}" >/dev/null ||
    die "The persisted ${stage} Terraform state is malformed or ambiguous; recover it manually before teardown."
}

calculate_terraform_state_binding_digest() {
  local state_file="$1"
  local canonical_state

  canonical_state="$(jq -ceS '.' "${state_file}")" ||
    die "Could not canonicalize the Terraform state binding."
  read -r TERRAFORM_STATE_BINDING_DIGEST _ < <(sha256sum <<<"${canonical_state}")
  [[ "${TERRAFORM_STATE_BINDING_DIGEST}" =~ ^[a-f0-9]{64}$ ]] ||
    die "Could not calculate the Terraform state binding digest."
}

require_stage_state_generation() {
  local stage="$1"
  local expected_generation="$2"
  local current_generation

  inspect_stage_state_object "${stage}"
  [[ "${DISCOVERED_STATE_STATUS}" == "present" ]] ||
    die "The exact persisted ${stage} state object became unavailable, noncurrent-only, or soft-deleted-only; refusing Terraform initialization or planning."
  current_generation="${DISCOVERED_STATE_GENERATION}"
  [[ "${current_generation}" == "${expected_generation}" ]] ||
    die "The persisted ${stage} state changed concurrently. No destroy plan was evaluated; rerun teardown from a fresh state inspection."
}

read_persisted_stage_state() {
  local stage="$1"
  local destination_file="$2"
  local state_uri="gs://${TF_STATE_BUCKET}/${stage}/default.tfstate"

  PERSISTED_STATE_GENERATION=""
  inspect_stage_state_object "${stage}"
  case "${DISCOVERED_STATE_STATUS}" in
    present) PERSISTED_STATE_GENERATION="${DISCOVERED_STATE_GENERATION}" ;;
    historical-only)
      die "Persisted ${stage} state has only noncurrent or soft-deleted generations; recover the exact live state before Terraform initialization."
      ;;
    absent)
      die "The exact persisted ${stage} state object is absent; refusing Terraform initialization."
      ;;
    *) die "Internal persisted ${stage} state classification error." ;;
  esac

  install -m 0600 /dev/null "${destination_file}"
  refresh_adc_token
  if ! gcloud --access-token-file="${adc_token_file}" storage cat \
    "${state_uri}" >"${destination_file}" 2>/dev/null; then
    die "The exact persisted ${stage} state object exists but could not be read before Terraform initialization."
  fi
  chmod 0600 "${destination_file}"
  validate_terraform_state_snapshot "${destination_file}" "${stage}"
  require_stage_state_generation "${stage}" "${PERSISTED_STATE_GENERATION}"
}

validate_completion_marker_contents() {
  local marker_file="$1"

  jq -e --arg project "${PROJECT_ID}" --arg bucket "${TF_STATE_BUCKET}" \
    --arg platform_object "platform/default.tfstate" \
    --arg foundation_object "foundation/default.tfstate" \
    --arg inventory_object "${REMOTE_INVENTORY_OBJECT}" '
      type == "object" and
      (keys == ["completed_at_utc", "controller_inventory", "foundation", "platform",
        "project_id", "state_bucket", "version"]) and
      .version == 1 and
      .project_id == $project and
      .state_bucket == $bucket and
      (.completed_at_utc | type == "string" and
        test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")) and
      all([.platform, .foundation][];
        type == "object" and
        (keys == ["binding_digest", "generation", "lineage", "object", "serial"]) and
        (.generation | type == "string" and test("^[1-9][0-9]*$")) and
        (.lineage | type == "string" and
          test("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")) and
        (.serial | type == "number" and . >= 0 and floor == .) and
        (.binding_digest | type == "string" and test("^[a-f0-9]{64}$"))
      ) and
      .platform.object == $platform_object and
      .foundation.object == $foundation_object and
      (.controller_inventory | type == "object") and
      (.controller_inventory |
        keys == ["generation", "identity_digest", "known_generations", "object"]) and
      .controller_inventory.object == $inventory_object and
      (.controller_inventory.generation | type == "string" and test("^[1-9][0-9]*$")) and
      (.controller_inventory.identity_digest | type == "string" and test("^[a-f0-9]{64}$")) and
      (.controller_inventory.known_generations | type == "array" and length > 0) and
      all(.controller_inventory.known_generations[];
        type == "string" and test("^[1-9][0-9]*$")) and
      (.controller_inventory.known_generations | unique | length) ==
        (.controller_inventory.known_generations | length) and
      (.controller_inventory.generation as $generation |
        .controller_inventory.known_generations | index($generation)) != null
    ' "${marker_file}" >/dev/null ||
    die "The live teardown completion marker is malformed or does not match this project and state bucket."
}

read_completion_marker() {
  local destination_file="$1"
  local discovered_generation

  COMPLETION_MARKER_GENERATION=""
  inspect_versioned_object "${COMPLETION_MARKER_OBJECT}" "teardown completion marker object"
  case "${DISCOVERED_STATE_STATUS}" in
    present) discovered_generation="${DISCOVERED_STATE_GENERATION}" ;;
    historical-only)
      die "The teardown completion marker has only noncurrent or soft-deleted generations; it cannot authorize an empty-platform shortcut."
      ;;
    absent)
      die "No live teardown completion marker binds the empty platform state; controller cleanup cannot be inferred."
      ;;
    *) die "Internal teardown completion marker classification error." ;;
  esac

  install -m 0600 /dev/null "${destination_file}"
  refresh_adc_token
  if ! gcloud --access-token-file="${adc_token_file}" storage cat \
    "${COMPLETION_MARKER_URI}" >"${destination_file}" 2>/dev/null; then
    die "The live teardown completion marker exists but could not be read."
  fi
  chmod 0600 "${destination_file}"
  validate_completion_marker_contents "${destination_file}"
  require_versioned_object_generation "${COMPLETION_MARKER_OBJECT}" \
    "teardown completion marker object" "${discovered_generation}"
  COMPLETION_MARKER_GENERATION="${discovered_generation}"
}

validate_controller_inventory_history_chain() {
  local current_generation
  local observed_generations_json
  local prior_marker_generations_json="[]"
  local allowed_generations_json

  require_matching_local_and_durable_inventory
  current_generation="${REMOTE_INVENTORY_GENERATION}"
  observed_generations_json="${DISCOVERED_STATE_GENERATIONS_JSON}"

  inspect_versioned_object "${COMPLETION_MARKER_OBJECT}" "teardown completion marker object"
  case "${DISCOVERED_STATE_STATUS}" in
    present)
      read_completion_marker "${completion_marker_snapshot}"
      VALIDATED_MARKER_REPLACEMENT_GENERATION="${COMPLETION_MARKER_GENERATION}"
      prior_marker_generations_json="$(jq -cer \
        '.controller_inventory.known_generations' "${completion_marker_snapshot}")"
      ;;
    historical-only|absent) VALIDATED_MARKER_REPLACEMENT_GENERATION="0" ;;
    *) die "Internal teardown completion marker history-chain classification error." ;;
  esac
  allowed_generations_json="$(jq -cn \
    --arg current "${current_generation}" \
    --argjson prior "${prior_marker_generations_json}" \
    '($prior + [$current]) | unique')"
  jq -en --argjson observed "${observed_generations_json}" \
    --argjson allowed "${allowed_generations_json}" \
    '($observed - $allowed | length) == 0' >/dev/null ||
    die "Controller recovery inventory history contains a generation not bound by the prior live completion marker or the current validated inventory."

  VALIDATED_INVENTORY_GENERATION="${current_generation}"
  VALIDATED_INVENTORY_GENERATIONS_JSON="${allowed_generations_json}"
}

capture_empty_stage_binding() {
  local stage="$1"
  local state_file="${temporary_root}/${stage}-completion-binding.tfstate"
  local generation
  local lineage
  local serial
  local binding_digest
  local resource_count
  local output_count

  read_persisted_stage_state "${stage}" "${state_file}"
  generation="${PERSISTED_STATE_GENERATION}"
  resource_count="$(jq -er '.resources | length' "${state_file}")"
  output_count="$(jq -er '.outputs | length' "${state_file}")"
  [[ "${resource_count}:${output_count}" == "0:0" ]] ||
    die "The persisted ${stage} state is not empty; refusing to bind a teardown completion marker."
  lineage="$(jq -er '.lineage' "${state_file}")"
  serial="$(jq -er '.serial' "${state_file}")"
  calculate_terraform_state_binding_digest "${state_file}"
  binding_digest="${TERRAFORM_STATE_BINDING_DIGEST}"
  rm -f -- "${state_file}"

  case "${stage}" in
    platform)
      BOUND_PLATFORM_GENERATION="${generation}"
      BOUND_PLATFORM_LINEAGE="${lineage}"
      BOUND_PLATFORM_SERIAL="${serial}"
      BOUND_PLATFORM_DIGEST="${binding_digest}"
      ;;
    foundation)
      BOUND_FOUNDATION_GENERATION="${generation}"
      BOUND_FOUNDATION_LINEAGE="${lineage}"
      BOUND_FOUNDATION_SERIAL="${serial}"
      BOUND_FOUNDATION_DIGEST="${binding_digest}"
      ;;
    *) die "Internal completion binding stage error: ${stage}" ;;
  esac
}

require_completion_shortcut_evidence() {
  local marker_file="$1"
  local primary_cluster_recheck
  local secondary_cluster_recheck
  local inventory_status
  local inventory_generations_json

  inspect_cluster_existence "${PRIMARY_CLUSTER}" "${PRIMARY_REGION}"
  primary_cluster_recheck="${CLUSTER_PRESENT}"
  inspect_cluster_existence "${SECONDARY_CLUSTER}" "${SECONDARY_REGION}"
  secondary_cluster_recheck="${CLUSTER_PRESENT}"
  inspect_local_inventory
  [[ "${primary_cluster_recheck}:${secondary_cluster_recheck}" == "false:false" &&
    "${LOCAL_INVENTORY_PRESENT}" == "false" ]] ||
    die "A supported cluster or local controller inventory exists; the completion marker cannot authorize a platform shortcut."

  inspect_recovery_inventory_history
  inventory_status="${DISCOVERED_STATE_STATUS}"
  inventory_generations_json="${DISCOVERED_STATE_GENERATIONS_JSON}"
  [[ "${inventory_status}" != "present" ]] ||
    die "A live controller recovery inventory exists; the completion marker cannot authorize a platform shortcut."
  jq -e --argjson observed_generations "${inventory_generations_json}" '
      ($observed_generations - .controller_inventory.known_generations | length) == 0
    ' "${marker_file}" >/dev/null ||
    die "Controller recovery inventory history contains a generation not bound by the live teardown completion marker."
}

authorize_completed_empty_platform() {
  local state_file="${temporary_root}/platform-completion-authorization.tfstate"
  local platform_generation
  local platform_lineage
  local platform_serial
  local platform_digest
  local resource_count
  local output_count

  COMPLETION_SHORTCUT_AUTHORIZED="false"
  read_persisted_stage_state platform "${state_file}"
  platform_generation="${PERSISTED_STATE_GENERATION}"
  resource_count="$(jq -er '.resources | length' "${state_file}")"
  output_count="$(jq -er '.outputs | length' "${state_file}")"
  if ((resource_count > 0)); then
    rm -f -- "${state_file}"
    return 0
  fi
  [[ "${output_count}" == "0" ]] ||
    die "The persisted platform state has no resources but retains outputs; refusing the completion-marker shortcut."
  platform_lineage="$(jq -er '.lineage' "${state_file}")"
  platform_serial="$(jq -er '.serial' "${state_file}")"
  calculate_terraform_state_binding_digest "${state_file}"
  platform_digest="${TERRAFORM_STATE_BINDING_DIGEST}"
  rm -f -- "${state_file}"

  # Foundation may have been recreated, so authorization binds only the unchanged
  # empty platform state. The marker's foundation binding proves the prior teardown.
  read_completion_marker "${completion_marker_snapshot}"
  require_completion_shortcut_evidence "${completion_marker_snapshot}"
  jq -e --arg generation "${platform_generation}" \
    --arg lineage "${platform_lineage}" \
    --argjson serial "${platform_serial}" \
    --arg digest "${platform_digest}" '
      .platform.generation == $generation and
      .platform.lineage == $lineage and
      .platform.serial == $serial and
      .platform.binding_digest == $digest
    ' "${completion_marker_snapshot}" >/dev/null ||
    die "The live teardown completion marker does not bind the exact current empty platform state."
  require_stage_state_generation platform "${platform_generation}"
  require_versioned_object_generation "${COMPLETION_MARKER_OBJECT}" \
    "teardown completion marker object" "${COMPLETION_MARKER_GENERATION}"
  require_completion_shortcut_evidence "${completion_marker_snapshot}"
  require_stage_state_generation platform "${platform_generation}"
  require_versioned_object_generation "${COMPLETION_MARKER_OBJECT}" \
    "teardown completion marker object" "${COMPLETION_MARKER_GENERATION}"

  BOUND_PLATFORM_GENERATION="${platform_generation}"
  BOUND_PLATFORM_LINEAGE="${platform_lineage}"
  BOUND_PLATFORM_SERIAL="${platform_serial}"
  BOUND_PLATFORM_DIGEST="${platform_digest}"
  COMPLETION_SHORTCUT_AUTHORIZED="true"
}

persist_completion_marker() {
  local marker_candidate="${temporary_root}/teardown-completion-candidate.json"
  local expected_marker_generation="0"
  local inventory_generation
  local inventory_identity_digest
  local inventory_generations_json
  local candidate_digest
  local stored_digest
  local primary_cluster_recheck
  local secondary_cluster_recheck

  [[ "${REMOTE_INVENTORY_PRESENT}" == "true" ]] ||
    die "A validated live controller inventory is required before recording strict teardown completion."

  capture_empty_stage_binding platform
  capture_empty_stage_binding foundation
  inspect_cluster_existence "${PRIMARY_CLUSTER}" "${PRIMARY_REGION}"
  primary_cluster_recheck="${CLUSTER_PRESENT}"
  inspect_cluster_existence "${SECONDARY_CLUSTER}" "${SECONDARY_REGION}"
  secondary_cluster_recheck="${CLUSTER_PRESENT}"
  [[ "${primary_cluster_recheck}:${secondary_cluster_recheck}" == "false:false" ]] ||
    die "A supported cluster remains after empty state verification; refusing to record teardown completion."
  validate_controller_inventory_history_chain
  inventory_generation="${VALIDATED_INVENTORY_GENERATION}"
  inventory_generations_json="${VALIDATED_INVENTORY_GENERATIONS_JSON}"
  expected_marker_generation="${VALIDATED_MARKER_REPLACEMENT_GENERATION}"
  calculate_inventory_identity_digest "${INVENTORY_FILE}"
  inventory_identity_digest="${INVENTORY_IDENTITY_DIGEST}"

  install -m 0600 /dev/null "${marker_candidate}"
  jq -n --arg project "${PROJECT_ID}" --arg bucket "${TF_STATE_BUCKET}" \
    --arg completed_at "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
    --arg platform_generation "${BOUND_PLATFORM_GENERATION}" \
    --arg platform_lineage "${BOUND_PLATFORM_LINEAGE}" \
    --argjson platform_serial "${BOUND_PLATFORM_SERIAL}" \
    --arg platform_digest "${BOUND_PLATFORM_DIGEST}" \
    --arg foundation_generation "${BOUND_FOUNDATION_GENERATION}" \
    --arg foundation_lineage "${BOUND_FOUNDATION_LINEAGE}" \
    --argjson foundation_serial "${BOUND_FOUNDATION_SERIAL}" \
    --arg foundation_digest "${BOUND_FOUNDATION_DIGEST}" \
    --arg inventory_object "${REMOTE_INVENTORY_OBJECT}" \
    --arg inventory_generation "${inventory_generation}" \
    --arg inventory_digest "${inventory_identity_digest}" \
    --argjson inventory_generations "${inventory_generations_json}" '
      {
        version: 1,
        project_id: $project,
        state_bucket: $bucket,
        completed_at_utc: $completed_at,
        platform: {
          object: "platform/default.tfstate",
          generation: $platform_generation,
          lineage: $platform_lineage,
          serial: $platform_serial,
          binding_digest: $platform_digest
        },
        foundation: {
          object: "foundation/default.tfstate",
          generation: $foundation_generation,
          lineage: $foundation_lineage,
          serial: $foundation_serial,
          binding_digest: $foundation_digest
        },
        controller_inventory: {
          object: $inventory_object,
          generation: $inventory_generation,
          identity_digest: $inventory_digest,
          known_generations: $inventory_generations
        }
      }
    ' >"${marker_candidate}"
  chmod 0600 "${marker_candidate}"
  validate_completion_marker_contents "${marker_candidate}"
  calculate_file_digest "${marker_candidate}"
  candidate_digest="${FILE_DIGEST}"

  # Persist first, while the live inventory still blocks shortcut authorization.
  # The caller removes that exact inventory generation only after this verification.
  refresh_adc_token
  if ! gcloud --access-token-file="${adc_token_file}" storage cp \
    "${marker_candidate}" "${COMPLETION_MARKER_URI}" \
    --if-generation-match="${expected_marker_generation}" --quiet >/dev/null 2>&1; then
    die "Could not persist the teardown completion marker with its generation precondition; the controller inventory was retained."
  fi
  read_completion_marker "${completion_marker_snapshot}"
  calculate_file_digest "${completion_marker_snapshot}"
  stored_digest="${FILE_DIGEST}"
  [[ "${stored_digest}" == "${candidate_digest}" ]] ||
    die "The stored teardown completion marker differs from the verified candidate; the controller inventory was retained."
  require_stage_state_generation platform "${BOUND_PLATFORM_GENERATION}"
  require_stage_state_generation foundation "${BOUND_FOUNDATION_GENERATION}"
  validate_controller_inventory_history_chain
  [[ "${VALIDATED_INVENTORY_GENERATION}" == "${inventory_generation}" &&
    "${VALIDATED_INVENTORY_GENERATIONS_JSON}" == "${inventory_generations_json}" ]] ||
    die "The controller recovery inventory changed while recording teardown completion."
}

TERRAFORM_STAGE_RESULT=""

skip_never_created_stage() {
  local stage="$1"
  local primary_cluster_recheck
  local secondary_cluster_recheck

  [[ "${stage}" == "platform" ]] || die "Only the platform stage can be skipped as never-created."
  inspect_stage_state_object "${stage}"
  [[ "${DISCOVERED_STATE_STATUS}" == "absent" ]] ||
    die "Platform state appeared or historical state became visible after foundation-only preflight; refusing to skip it."
  inspect_cluster_existence "${PRIMARY_CLUSTER}" "${PRIMARY_REGION}"
  primary_cluster_recheck="${CLUSTER_PRESENT}"
  inspect_cluster_existence "${SECONDARY_CLUSTER}" "${SECONDARY_REGION}"
  secondary_cluster_recheck="${CLUSTER_PRESENT}"
  inspect_local_inventory
  discover_remote_inventory "${remote_inventory_snapshot}"
  inspect_recovery_inventory_history
  inspect_completion_marker_history
  if [[ "${primary_cluster_recheck}:${secondary_cluster_recheck}" != "false:false" ||
    "${LOCAL_INVENTORY_PRESENT}:${REMOTE_INVENTORY_PRESENT}" != "false:false" ||
    "${RECOVERY_INVENTORY_HISTORY_PRESENT}:${COMPLETION_MARKER_HISTORY_PRESENT}" != "false:false" ]]; then
    die "Cluster, controller-recovery, or teardown-completion evidence appeared after genuinely-never-created preflight; refusing to skip the platform stage."
  fi
  TERRAFORM_STAGE_RESULT="skipped-never-created"
  printf '%s\n' 'Platform state, supported clusters, controller inventory, and completion marker remain wholly absent; skipping platform init, destroy plan, and apply.'
}

skip_completion_bound_empty_stage() {
  local stage="$1"

  [[ "${stage}" == "platform" ]] ||
    die "Only the platform stage can be skipped from a teardown completion marker."
  authorize_completed_empty_platform
  [[ "${COMPLETION_SHORTCUT_AUTHORIZED}" == "true" ]] ||
    die "The completion-bound platform state became resource-bearing before the final skip check."
  TERRAFORM_STAGE_RESULT="skipped-completion-bound-empty"
  printf '%s\n' 'The exact empty platform state and completion marker remain generation-stable, both clusters remain absent, and no live controller inventory exists; skipping platform init, destroy plan, and apply.'
}

terraform_destroy_stage() {
  local stage="$1"
  local terraform_root
  local plan_file
  local plan_summary
  local preinit_state_file
  local postinit_state_file
  local persisted_generation
  local state_resource_count
  local state_output_count
  local preinit_lineage
  local postinit_lineage
  local preinit_serial
  local postinit_serial
  local preinit_binding_digest
  local postinit_binding_digest

  case "${stage}" in
    platform|foundation) ;;
    bootstrap|*) die "Refusing teardown of Terraform root: ${stage}" ;;
  esac
  TERRAFORM_STAGE_RESULT=""
  terraform_root="${REPO_ROOT}/infra/${stage}"
  plan_file="${temporary_root}/${stage}-destroy.tfplan"
  preinit_state_file="${temporary_root}/${stage}-persisted-preinit.tfstate"
  postinit_state_file="${temporary_root}/${stage}-postinit-pull.tfstate"

  read_persisted_stage_state "${stage}" "${preinit_state_file}"
  persisted_generation="${PERSISTED_STATE_GENERATION}"
  state_resource_count="$(jq -er '.resources | length' "${preinit_state_file}")"
  state_output_count="$(jq -er '.outputs | length' "${preinit_state_file}")"
  if [[ "${state_resource_count}" == "0" ]]; then
    [[ "${state_output_count}" == "0" ]] ||
      die "The persisted ${stage} state has no resources but retains outputs; refusing to classify it as safely destroyed."
    require_stage_state_generation "${stage}" "${persisted_generation}"
    printf 'Terraform %s persisted remote state is valid and already empty; skipping init, destroy plan, and apply.\n' "${stage}"
    rm -f -- "${preinit_state_file}"
    TERRAFORM_STAGE_RESULT="already-empty"
    return 0
  fi

  preinit_lineage="$(jq -er '.lineage' "${preinit_state_file}")"
  preinit_serial="$(jq -er '.serial' "${preinit_state_file}")"
  calculate_terraform_state_binding_digest "${preinit_state_file}"
  preinit_binding_digest="${TERRAFORM_STATE_BINDING_DIGEST}"

  TF_WORKSPACE=default terraform -chdir="${terraform_root}" init -input=false -reconfigure \
    -backend-config="bucket=${TF_STATE_BUCKET}" -backend-config="prefix=${stage}"
  install -m 0600 /dev/null "${postinit_state_file}"
  if ! TF_WORKSPACE=default terraform -chdir="${terraform_root}" state pull \
    >"${postinit_state_file}" 2>/dev/null; then
    die "Could not pull the pre-existing ${stage} remote state after backend initialization; refusing to evaluate a destroy plan."
  fi
  chmod 0600 "${postinit_state_file}"
  validate_terraform_state_snapshot "${postinit_state_file}" "${stage}"
  require_stage_state_generation "${stage}" "${persisted_generation}"
  postinit_lineage="$(jq -er '.lineage' "${postinit_state_file}")"
  postinit_serial="$(jq -er '.serial' "${postinit_state_file}")"
  [[ "${postinit_lineage}" == "${preinit_lineage}" ]] ||
    die "Terraform initialized ${stage} against a different state lineage; refusing to plan from an unbound backend."
  if ((postinit_serial < preinit_serial)); then
    die "Terraform returned a regressed ${stage} state serial; refusing to plan from an unbound backend."
  fi
  [[ "${postinit_serial}" == "${preinit_serial}" ]] ||
    die "The persisted ${stage} state changed concurrently after inspection. No destroy plan was evaluated; rerun teardown."
  calculate_terraform_state_binding_digest "${postinit_state_file}"
  postinit_binding_digest="${TERRAFORM_STATE_BINDING_DIGEST}"
  [[ "${postinit_binding_digest}" == "${preinit_binding_digest}" ]] ||
    die "Terraform's pulled ${stage} state does not canonically match the pre-init persisted snapshot; refusing to plan from an unbound backend."
  rm -f -- "${preinit_state_file}" "${postinit_state_file}"

  TF_WORKSPACE=default terraform -chdir="${terraform_root}" plan -destroy -input=false \
    -var="terraform_state_bucket=${TF_STATE_BUCKET}" -out="${plan_file}" >/dev/null
  chmod 0600 "${plan_file}"
  plan_summary="$(TF_WORKSPACE=default terraform -chdir="${terraform_root}" show -json "${plan_file}" |
    jq -r '.resource_changes[]? |
      select(.change.actions != ["no-op"]) |
      [.address, (.change.actions | join(","))] | @tsv')"
  printf 'Terraform %s destroy actions (resource address and action type only):\n' "${stage}"
  if [[ -n "${plan_summary}" ]]; then
    printf '%s\n' "${plan_summary}"
  else
    printf '%s\n' 'No resource changes.'
  fi
  TF_WORKSPACE=default terraform -chdir="${terraform_root}" apply -input=false -auto-approve "${plan_file}"
  rm -f -- "${plan_file}"
  TERRAFORM_STAGE_RESULT="destroyed"
}

prepare_teardown_cleanup

if [[ "${platform_never_created}" == "true" ]]; then
  skip_never_created_stage platform
elif [[ "${platform_completed_empty}" == "true" ]]; then
  skip_completion_bound_empty_stage platform
else
  terraform_destroy_stage platform
fi
platform_stage_result="${TERRAFORM_STAGE_RESULT}"
terraform_destroy_stage foundation
foundation_stage_result="${TERRAFORM_STAGE_RESULT}"

report_dir="${REPO_ROOT}/artifacts/live"
report_file="${report_dir}/teardown-$(date -u +'%Y%m%dT%H%M%SZ').txt"
mkdir -p "${report_dir}"
install -m 0600 /dev/null "${report_file}"
{
  printf 'timestamp_utc=%s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  printf 'project=%s\n' "${PROJECT_ID}"
  printf 'kubernetes_cleanup=%s\n' "${kubernetes_cleanup_result}"
  printf 'multicluster_cleanup=%s\n' "${multicluster_cleanup_result}"
  printf 'platform_stage=%s\n' "${platform_stage_result}"
  printf 'foundation_stage=%s\n' "${foundation_stage_result}"
  printf 'retained_state_bucket=%s\n' "${TF_STATE_BUCKET}"
  printf 'retained_wif_provider=%s\n' "${GCP_WIF_PROVIDER}"
  printf 'retained_deployer_identity=%s\n' "${GCP_DEPLOYER_SERVICE_ACCOUNT}"
  printf '%s\n' 'retained_bootstrap_state=bootstrap'
  if [[ "${REMOTE_INVENTORY_PRESENT}" == "true" ]]; then
    printf '%s\n' 'controller_recovery_inventory=retained-through-successful-report'
  elif [[ "${platform_completed_empty}" == "true" ]]; then
    printf '%s\n' 'controller_recovery_inventory=not-required-completion-bound-empty-platform'
  else
    printf '%s\n' 'controller_recovery_inventory=not-created-platform-never-created'
  fi
} | tee "${report_file}"
if [[ "${REMOTE_INVENTORY_PRESENT}" == "true" ]]; then
  persist_completion_marker
  printf '%s\n' 'teardown_completion_marker=persisted-and-state-bound-before-inventory-removal' | tee -a "${report_file}"
  remove_recovery_inventories
  authorize_completed_empty_platform
  [[ "${COMPLETION_SHORTCUT_AUTHORIZED}" == "true" ]] ||
    die "The newly recorded teardown completion marker did not authorize the exact empty platform state after inventory removal."
  printf '%s\n' 'controller_recovery_inventory=live-generation-removed-after-successful-teardown' | tee -a "${report_file}"
  printf '%s\n' 'teardown_completion_marker=active-for-exact-empty-platform-state' | tee -a "${report_file}"
elif [[ "${platform_completed_empty}" == "true" ]]; then
  printf '%s\n' 'teardown_completion_marker=reused-for-exact-empty-platform-state' | tee -a "${report_file}"
else
  printf '%s\n' 'teardown_completion_marker=not-created-platform-never-created' | tee -a "${report_file}"
fi
printf '%s\n' 'Teardown completed. Bootstrap state, WIF, deployer identity, and state bucket were intentionally retained.'
