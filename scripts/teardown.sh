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

terraform -chdir="${REPO_ROOT}/infra/platform" init -input=false -reconfigure \
  -backend-config="bucket=${TF_STATE_BUCKET}" -backend-config="prefix=platform" >/dev/null
global_ipv4_address="$(terraform -chdir="${REPO_ROOT}/infra/platform" output -raw global_ipv4_address)"

dns_primary="${temporary_root}/dns-primary.kubeconfig"
dns_secondary="${temporary_root}/dns-secondary.kubeconfig"
get_dns_credentials "${PRIMARY_CLUSTER}" "${PRIMARY_REGION}" "${dns_primary}"
get_dns_credentials "${SECONDARY_CLUSTER}" "${SECONDARY_REGION}" "${dns_secondary}"

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

deadline=$((SECONDS + LOAD_BALANCER_TIMEOUT_SECONDS))
while ((SECONDS < deadline)); do
  forwarding_rule_count="$(gcloud compute forwarding-rules list --global --project="${PROJECT_ID}" \
    --filter="IPAddress=${global_ipv4_address}" --format=json | jq -er 'length')"
  if [[ "${forwarding_rule_count}" == "0" ]]; then
    break
  fi
  sleep 20
done
[[ "${forwarding_rule_count}" == "0" ]] ||
  die "Managed load-balancer forwarding rules did not clean up before the bounded timeout."
printf '%s\n' 'Managed load-balancer forwarding rules have been removed.'

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
