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

for command_name in git terraform jq gcloud kubectl; do
  require_command "${command_name}"
done

temporary_root="$(mktemp -d "${TMPDIR:-/tmp}/gke-assessment-teardown.XXXXXX")"
chmod 0700 "${temporary_root}"
cleanup() {
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
    printf '%s\t%s\n' "${resource_kind}" "${resource_name}" >>"${destination}"
    count=$((count + 1))
  done <<<"${raw_values}"
  ((count > 0)) || die "MultiClusterIngress status exposes empty ${resource_kind} inventory."
}

compute_resource_exists() {
  local resource_kind="$1"
  local resource_name="$2"
  local resource_inventory
  local resource_count

  case "${resource_kind}" in
    forwarding-rule)
      resource_inventory="$(gcloud compute forwarding-rules list --global \
        --project="${PROJECT_ID}" --format=json 2>/dev/null)" ||
        die "Could not inspect controller forwarding rules."
      ;;
    target-http-proxy)
      resource_inventory="$(gcloud compute target-http-proxies list --global \
        --project="${PROJECT_ID}" --format=json 2>/dev/null)" ||
        die "Could not inspect controller HTTP target proxies."
      ;;
    target-https-proxy)
      resource_inventory="$(gcloud compute target-https-proxies list --global \
        --project="${PROJECT_ID}" --format=json 2>/dev/null)" ||
        die "Could not inspect controller HTTPS target proxies."
      ;;
    url-map)
      resource_inventory="$(gcloud compute url-maps list --global \
        --project="${PROJECT_ID}" --format=json 2>/dev/null)" ||
        die "Could not inspect controller URL maps."
      ;;
    health-check)
      resource_inventory="$(gcloud compute health-checks list --global \
        --project="${PROJECT_ID}" --format=json 2>/dev/null)" ||
        die "Could not inspect controller health checks."
      ;;
    backend-service)
      resource_inventory="$(gcloud compute backend-services list --global \
        --project="${PROJECT_ID}" --format=json 2>/dev/null)" ||
        die "Could not inspect controller backend services."
      ;;
    firewall-rule)
      resource_inventory="$(gcloud compute firewall-rules list \
        --project="${PROJECT_ID}" --format=json 2>/dev/null)" ||
        die "Could not inspect controller firewall rules."
      ;;
    ssl-certificate)
      resource_inventory="$(gcloud compute ssl-certificates list --global \
        --project="${PROJECT_ID}" --format=json 2>/dev/null)" ||
        die "Could not inspect controller SSL certificates."
      ;;
    *) die "Internal controller-resource kind error: ${resource_kind}" ;;
  esac
  resource_count="$(jq -er --arg name "${resource_name}" \
    '[.[] | select(.name == $name)] | length' <<<"${resource_inventory}")"
  [[ "${resource_count}" == "0" || "${resource_count}" == "1" ]] ||
    die "Controller resource lookup returned an ambiguous result."
  [[ "${resource_count}" == "1" ]]
}

capture_controller_inventory() {
  local mci_json="$1"
  local raw_inventory="$2"
  local resolved_inventory="$3"
  local resource_kind
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

  while IFS=$'\t' read -r resource_kind resource_name; do
    if [[ "${resource_kind}" != "target-proxy" ]]; then
      printf '%s\t%s\n' "${resource_kind}" "${resource_name}" >>"${resolved_inventory}"
      continue
    fi
    http_exists=false
    https_exists=false
    if compute_resource_exists target-http-proxy "${resource_name}"; then
      http_exists=true
    fi
    if compute_resource_exists target-https-proxy "${resource_name}"; then
      https_exists=true
    fi
    if [[ "${http_exists}:${https_exists}" == "true:false" ]]; then
      printf 'target-http-proxy\t%s\n' "${resource_name}" >>"${resolved_inventory}"
    elif [[ "${http_exists}:${https_exists}" == "false:true" ]]; then
      printf 'target-https-proxy\t%s\n' "${resource_name}" >>"${resolved_inventory}"
    else
      die "Could not uniquely resolve a controller target proxy from MultiClusterIngress status."
    fi
  done <"${raw_inventory}"
  [[ -s "${resolved_inventory}" ]] || die "Controller resource inventory is empty."
}

wait_for_controller_cleanup() {
  local inventory_file="$1"
  local deadline=$((SECONDS + LOAD_BALANCER_TIMEOUT_SECONDS))
  local resource_kind
  local resource_name
  local remaining_count

  while ((SECONDS < deadline)); do
    remaining_count=0
    while IFS=$'\t' read -r resource_kind resource_name; do
      if compute_resource_exists "${resource_kind}" "${resource_name}"; then
        remaining_count=$((remaining_count + 1))
      fi
    done <"${inventory_file}"
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

mci_json="$(KUBECONFIG="${dns_primary}" kubectl -n assessment get \
  multiclusteringress.networking.gke.io/assessment-ingress -o json)" ||
  die "MultiClusterIngress inventory is unavailable; refusing destructive Terraform teardown."
raw_inventory="${temporary_root}/mci-controller-inventory.raw.tsv"
controller_inventory="${temporary_root}/mci-controller-inventory.tsv"
capture_controller_inventory "${mci_json}" "${raw_inventory}" "${controller_inventory}"

printf '%s\n' 'Deleting MultiClusterIngress and MultiClusterService resources first.'
KUBECONFIG="${dns_primary}" kubectl -n assessment delete \
  multiclusteringress.networking.gke.io/assessment-ingress \
  --ignore-not-found --wait=true --timeout=20m
KUBECONFIG="${dns_primary}" kubectl -n assessment delete \
  multiclusterservice.networking.gke.io/app-a-mcs \
  multiclusterservice.networking.gke.io/app-b-mcs \
  --ignore-not-found --wait=true --timeout=20m
KUBECONFIG="${dns_primary}" kubectl -n assessment delete \
  frontendconfig.networking.gke.io/assessment-https \
  backendconfig.cloud.google.com/app-a-backend \
  backendconfig.cloud.google.com/app-b-backend \
  --ignore-not-found --wait=true --timeout=10m

wait_for_controller_cleanup "${controller_inventory}"

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
printf '%s\n' 'Teardown completed. Bootstrap state, WIF, deployer identity, and state bucket were intentionally retained.'
