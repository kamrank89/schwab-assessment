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
INVENTORY_FILE="${INVENTORY_DIR}/teardown-controller-inventory.json"

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

if [[ "${GITHUB_ACTIONS:-false}" == "true" ]]; then
  [[ "${GITHUB_REF:-}" == "refs/heads/main" ]] || die "Teardown may run only from the main branch."
else
  [[ "$(git -C "${REPO_ROOT}" branch --show-current)" == "main" ]] ||
    die "Teardown may run only from the main branch."
fi

for command_name in git terraform jq gcloud kubectl stat; do
  require_command "${command_name}"
done

temporary_root="$(mktemp -d "${TMPDIR:-/tmp}/gke-assessment-teardown.XXXXXX")"
chmod 0700 "${temporary_root}"
inventory_candidate=""
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
    '.status.cloudResources.ForwardingRules // .status.cloudResources.forwardingRules' "${raw_inventory}"
  append_status_inventory "${mci_json}" target-proxy \
    '.status.cloudResources.TargetProxies // .status.cloudResources.targetProxies' "${raw_inventory}"
  append_status_inventory "${mci_json}" url-map \
    '.status.cloudResources.UrlMap // .status.cloudResources.urlMap // .status.cloudResources.UrlMaps // .status.cloudResources.urlMaps' "${raw_inventory}"
  append_status_inventory "${mci_json}" health-check \
    '.status.cloudResources.HealthChecks // .status.cloudResources.healthChecks' "${raw_inventory}"
  append_status_inventory "${mci_json}" backend-service \
    '.status.cloudResources.BackendServices // .status.cloudResources.backendServices' "${raw_inventory}"
  append_status_inventory "${mci_json}" firewall-rule \
    '.status.cloudResources.Firewalls // .status.cloudResources.firewalls // .status.cloudResources.FirewallRules // .status.cloudResources.firewallRules' "${raw_inventory}"

  # Certificates referenced by networking.gke.io/pre-shared-certs are owned by
  # Terraform in this repository. Only inventory a certificate when the MCI
  # spec asks the controller to create one from a Kubernetes TLS Secret.
  controller_tls_secret_count="$(jq -er \
    '[.spec.template.spec.tls[]? | select(.secretName | type == "string" and length > 0)] | length' \
    <<<"${mci_json}")"
  if ((controller_tls_secret_count > 0)); then
    append_status_inventory "${mci_json}" ssl-certificate \
      '.status.cloudResources.SSLCertificates // .status.cloudResources.SslCertificates // .status.cloudResources.sslCertificates // .status.cloudResources.Certificates // .status.cloudResources.certificates' "${raw_inventory}"
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
    if [[ "${http_exists}:${https_exists}" == "true:false" ]]; then
      printf 'target-http-proxy\tglobal\tglobal\t%s\n' "${resource_name}" >>"${resolved_inventory}"
    elif [[ "${http_exists}:${https_exists}" == "false:true" ]]; then
      printf 'target-https-proxy\tglobal\tglobal\t%s\n' "${resource_name}" >>"${resolved_inventory}"
    else
      die "Could not uniquely resolve a controller target proxy from MultiClusterIngress status."
    fi
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

  jq -e --arg project "${PROJECT_ID}" --arg namespace "${MCI_NAMESPACE}" --arg name "${MCI_NAME}" '
    .resources as $resources |
    (keys | sort) == ["captured_at_utc", "mci", "preflighted", "project_id", "resources", "version"] and
    .version == 1 and
    .preflighted == true and
    .project_id == $project and
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

persist_preflighted_inventory() {
  local inventory_tsv="$1"
  local mci_uid="$2"

  if [[ -e "${INVENTORY_DIR}" || -L "${INVENTORY_DIR}" ]]; then
    [[ -d "${INVENTORY_DIR}" && ! -L "${INVENTORY_DIR}" ]] ||
      die "Ignored .generated path is not a regular directory; refusing inventory persistence."
  else
    install -d -m 0700 "${INVENTORY_DIR}"
  fi
  inventory_candidate="$(mktemp "${INVENTORY_DIR}/teardown-controller-inventory.XXXXXX")"
  chmod 0600 "${inventory_candidate}"
  jq -Rn --arg project "${PROJECT_ID}" --arg namespace "${MCI_NAMESPACE}" \
    --arg name "${MCI_NAME}" --arg uid "${mci_uid}" \
    --arg captured_at "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" '
      [inputs | split("\t") |
        {kind: .[0], scope: .[1], location: .[2], name: .[3]}] |
      {
        version: 1,
        preflighted: true,
        project_id: $project,
        captured_at_utc: $captured_at,
        mci: {namespace: $namespace, name: $name, uid: $uid},
        resources: .
      }
    ' <"${inventory_tsv}" >"${inventory_candidate}"
  chmod 0600 "${inventory_candidate}"
  validate_persisted_inventory_contents "${inventory_candidate}"
  mv -fT -- "${inventory_candidate}" "${INVENTORY_FILE}"
  inventory_candidate=""
  chmod 0600 "${INVENTORY_FILE}"
}

load_persisted_inventory() {
  [[ -e "${INVENTORY_FILE}" || -L "${INVENTORY_FILE}" ]] ||
    die "MultiClusterIngress is absent and no persisted controller inventory exists. Restore the MCI or recover its exact cloud resource inventory before teardown."
  [[ -f "${INVENTORY_FILE}" && ! -L "${INVENTORY_FILE}" &&
    -r "${INVENTORY_FILE}" && -O "${INVENTORY_FILE}" ]] ||
    die "Persisted teardown inventory has a suspicious file type or owner; recover it manually before teardown."
  [[ "$(stat -c '%a' "${INVENTORY_FILE}")" == "600" ]] ||
    die "Persisted teardown inventory must have mode 0600."
  validate_persisted_inventory_contents "${INVENTORY_FILE}"
}

audit_persisted_inventory_access() {
  local resource_kind
  local resource_scope
  local resource_location
  local resource_name

  while IFS=$'\t' read -r resource_kind resource_scope resource_location resource_name; do
    lookup_compute_resource "${resource_kind}" "${resource_location}" "${resource_name}" || true
  done < <(jq -r '.resources[] | [.kind, .scope, .location, .name] | @tsv' "${INVENTORY_FILE}")
}

wait_for_controller_cleanup() {
  local inventory_file="$1"
  local deadline=$((SECONDS + LOAD_BALANCER_TIMEOUT_SECONDS))
  local resource_kind
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
      printf '%s\n' 'All controller-managed MultiClusterIngress cloud resources have been removed.'
      return 0
    fi
    sleep 20
  done
  die "${remaining_count} inventoried controller-managed cloud resources remain after the bounded timeout."
}

dns_primary="${temporary_root}/dns-primary.kubeconfig"
dns_secondary="${temporary_root}/dns-secondary.kubeconfig"
get_dns_credentials "${PRIMARY_CLUSTER}" "${PRIMARY_REGION}" "${dns_primary}"
get_dns_credentials "${SECONDARY_CLUSTER}" "${SECONDARY_REGION}" "${dns_secondary}"

mci_json="$(KUBECONFIG="${dns_primary}" kubectl -n "${MCI_NAMESPACE}" get \
  "multiclusteringress.networking.gke.io/${MCI_NAME}" --ignore-not-found -o json)" ||
  die "MultiClusterIngress lookup failed; refusing Kubernetes or Terraform mutation."
if [[ -n "${mci_json}" ]]; then
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
  printf '%s\n' 'Persisted the exact preflighted controller inventory before Kubernetes deletion.'
else
  load_persisted_inventory
  audit_persisted_inventory_access
  printf '%s\n' 'MultiClusterIngress is absent; resuming from its matching persisted controller inventory.'
fi

printf '%s\n' 'Deleting MultiClusterIngress and MultiClusterService resources first.'
KUBECONFIG="${dns_primary}" kubectl -n "${MCI_NAMESPACE}" delete \
  "multiclusteringress.networking.gke.io/${MCI_NAME}" \
  --ignore-not-found --wait=true --timeout=20m
KUBECONFIG="${dns_primary}" kubectl -n "${MCI_NAMESPACE}" delete \
  multiclusterservice.networking.gke.io/app-a-mcs \
  multiclusterservice.networking.gke.io/app-b-mcs \
  --ignore-not-found --wait=true --timeout=20m
KUBECONFIG="${dns_primary}" kubectl -n "${MCI_NAMESPACE}" delete \
  frontendconfig.networking.gke.io/assessment-https \
  backendconfig.cloud.google.com/app-a-backend \
  backendconfig.cloud.google.com/app-b-backend \
  --ignore-not-found --wait=true --timeout=10m

wait_for_controller_cleanup "${INVENTORY_FILE}"

printf '%s\n' 'Deleting regional workload and namespace resources.'
KUBECONFIG="${dns_secondary}" kubectl delete namespace assessment observability \
  --ignore-not-found --wait=true --timeout=10m
KUBECONFIG="${dns_primary}" kubectl delete namespace assessment observability \
  --ignore-not-found --wait=true --timeout=10m
for kubeconfig in "${dns_primary}" "${dns_secondary}"; do
  KUBECONFIG="${kubeconfig}" kubectl delete \
    clusterrole/assessment-deployer-gateway-impersonation \
    clusterrolebinding/assessment-deployer-gateway-impersonation \
    --ignore-not-found --wait=true --timeout=5m
done

terraform_destroy_stage() {
  local stage="$1"
  local terraform_root
  local plan_file
  local plan_summary

  case "${stage}" in
    platform|foundation) ;;
    bootstrap|*) die "Refusing teardown of Terraform root: ${stage}" ;;
  esac
  terraform_root="${REPO_ROOT}/infra/${stage}"
  plan_file="${temporary_root}/${stage}-destroy.tfplan"

  terraform -chdir="${terraform_root}" init -input=false -reconfigure \
    -backend-config="bucket=${TF_STATE_BUCKET}" -backend-config="prefix=${stage}"
  terraform -chdir="${terraform_root}" plan -destroy -input=false \
    -var="terraform_state_bucket=${TF_STATE_BUCKET}" -out="${plan_file}" >/dev/null
  chmod 0600 "${plan_file}"
  plan_summary="$(terraform -chdir="${terraform_root}" show -json "${plan_file}" |
    jq -r '.resource_changes[]? |
      select(.change.actions != ["no-op"]) |
      [.address, (.change.actions | join(","))] | @tsv')"
  printf 'Terraform %s destroy actions (resource address and action type only):\n' "${stage}"
  if [[ -n "${plan_summary}" ]]; then
    printf '%s\n' "${plan_summary}"
  else
    printf '%s\n' 'No resource changes.'
  fi
  terraform -chdir="${terraform_root}" apply -input=false -auto-approve "${plan_file}"
  rm -f -- "${plan_file}"
}

terraform_destroy_stage platform
terraform_destroy_stage foundation

report_dir="${REPO_ROOT}/artifacts/live"
report_file="${report_dir}/teardown-$(date -u +'%Y%m%dT%H%M%SZ').txt"
mkdir -p "${report_dir}"
install -m 0600 /dev/null "${report_file}"
{
  printf 'timestamp_utc=%s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  printf 'project=%s\n' "${PROJECT_ID}"
  printf '%s\n' 'deleted=kubernetes-workloads,multicluster-resources,platform,foundation'
  printf 'retained_state_bucket=%s\n' "${TF_STATE_BUCKET}"
  printf 'retained_wif_provider=%s\n' "${GCP_WIF_PROVIDER}"
  printf 'retained_deployer_identity=%s\n' "${GCP_DEPLOYER_SERVICE_ACCOUNT}"
  printf '%s\n' 'retained_bootstrap_state=bootstrap'
} | tee "${report_file}"
rm -f -- "${INVENTORY_FILE}"
printf '%s\n' 'Teardown completed. Bootstrap state, WIF, deployer identity, and state bucket were intentionally retained.'
