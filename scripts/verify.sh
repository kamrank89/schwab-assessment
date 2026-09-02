#!/usr/bin/env bash
set -euo pipefail
set +x

umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd -P)"
PRIMARY_REGION="us-central1"
SECONDARY_REGION="us-east1"
PRIMARY_CLUSTER="gke-assessment-us-central1"
SECONDARY_CLUSTER="gke-assessment-us-east1"
ROLLOUT_TIMEOUT="10m"
DRILL_TIMEOUT_SECONDS=600

usage() {
  cat <<'USAGE'
Usage:
  verify.sh smoke
  verify.sh hpa --region us-central1|us-east1 --confirm "HPA <region>"
  verify.sh failover --region us-central1|us-east1 --confirm "FAILOVER <region>"

Smoke verification is non-mutating. HPA and failover are controlled application
exercises; they do not simulate or claim a cluster or regional infrastructure outage.
USAGE
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Required command is missing: $1"
}

require_environment() {
  local variable_name="$1"
  [[ -n "${!variable_name:-}" ]] || die "Required environment variable is empty: ${variable_name}"
}

temporary_root=""
RESTORE_KUBECONFIG=""
RESTORE_OVERLAY=""
report_file=""

restore_committed_workloads() {
  local result=0

  if [[ -z "${RESTORE_KUBECONFIG}" || -z "${RESTORE_OVERLAY}" ]]; then
    return 0
  fi
  printf '%s\n' 'Restoring committed application workloads after controlled exercise.' >&2
  if ! kustomize build "${RESTORE_OVERLAY}" |
    KUBECONFIG="${RESTORE_KUBECONFIG}" kubectl apply -f - >/dev/null; then
    result=1
  fi
  for application in app-a app-b; do
    if ! KUBECONFIG="${RESTORE_KUBECONFIG}" kubectl -n assessment rollout status \
      "deployment/${application}" --timeout="${ROLLOUT_TIMEOUT}" >/dev/null; then
      result=1
    fi
  done
  return "${result}"
}

on_exit() {
  local status=$?
  trap - EXIT
  set +e
  if ! restore_committed_workloads; then
    printf '%s\n' 'ERROR: Failed to restore committed application workloads.' >&2
    if ((status == 0)); then
      status=1
    fi
  fi
  if [[ -n "${temporary_root}" ]]; then
    rm -rf -- "${temporary_root}"
  fi
  exit "${status}"
}
trap on_exit EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

record() {
  [[ -n "${report_file}" ]] || die "Internal error: verification report is not initialized."
  printf '%s\n' "$*" | tee -a "${report_file}"
}

validate_environment() {
  require_environment GCP_PROJECT_ID
  require_environment GCP_PROJECT_NUMBER
  require_environment GCP_DEPLOYER_SERVICE_ACCOUNT
  require_environment TF_STATE_BUCKET
  require_environment GCP_ENABLE_HTTPS

  [[ "${GCP_PROJECT_ID}" =~ ^[a-z][a-z0-9-]{4,28}[a-z0-9]$ ]] || die "Invalid GCP_PROJECT_ID."
  [[ "${GCP_PROJECT_NUMBER}" =~ ^[1-9][0-9]{5,19}$ ]] || die "Invalid GCP_PROJECT_NUMBER."
  [[ "${TF_STATE_BUCKET}" =~ ^[a-z0-9][a-z0-9._-]{1,61}[a-z0-9]$ ]] || die "Invalid TF_STATE_BUCKET."
  [[ "${GCP_ENABLE_HTTPS}" == "true" || "${GCP_ENABLE_HTTPS}" == "false" ]] ||
    die "GCP_ENABLE_HTTPS must be true or false."
  [[ "${GCP_DEPLOYER_SERVICE_ACCOUNT}" =~ ^[a-z][a-z0-9-]{4,28}[a-z0-9]@[a-z][a-z0-9-]{4,28}[a-z0-9]\.iam\.gserviceaccount\.com$ ]] ||
    die "Invalid GCP_DEPLOYER_SERVICE_ACCOUNT."
}

prepare_kubeconfig() {
  install -m 0600 /dev/null "$1"
}

get_gateway_credentials() {
  local membership="$1"
  local kubeconfig="$2"

  prepare_kubeconfig "${kubeconfig}"
  KUBECONFIG="${kubeconfig}" gcloud container fleet memberships get-credentials "${membership}" \
    --location=global --project="${GCP_PROJECT_ID}" --quiet >/dev/null
  chmod 0600 "${kubeconfig}"
}

platform_json=""
global_ipv4_address=""
bigquery_dataset=""
cloud_armor_policy_name=""
tls_certificate_name=""
gateway_primary=""
gateway_secondary=""
gateway_config=""

initialize_context() {
  local app_a_gsa_email
  local grafana_gsa_email

  for command_name in terraform jq gcloud kubectl kustomize curl bq; do
    require_command "${command_name}"
  done
  validate_environment

  temporary_root="$(mktemp -d "${TMPDIR:-/tmp}/gke-assessment-verify.XXXXXX")"
  chmod 0700 "${temporary_root}"
  terraform -chdir="${REPO_ROOT}/infra/platform" init -input=false -reconfigure \
    -backend-config="bucket=${TF_STATE_BUCKET}" -backend-config="prefix=platform" >/dev/null
  platform_json="$(terraform -chdir="${REPO_ROOT}/infra/platform" output -json)"
  app_a_gsa_email="$(jq -er '.app_a_runtime_gsa_email.value' <<<"${platform_json}")"
  grafana_gsa_email="$(jq -er '.grafana_runtime_gsa_email.value' <<<"${platform_json}")"
  global_ipv4_address="$(jq -er '.global_ipv4_address.value' <<<"${platform_json}")"
  bigquery_dataset="$(jq -er '.bigquery_dataset_id.value' <<<"${platform_json}")"
  cloud_armor_policy_name="$(jq -er '.cloud_armor_policy_name.value' <<<"${platform_json}")"
  tls_certificate_name="$(jq -r '.tls_certificate_name.value // ""' <<<"${platform_json}")"

  "${SCRIPT_DIR}/render-manifests.sh" \
    --project-id "${GCP_PROJECT_ID}" \
    --project-number "${GCP_PROJECT_NUMBER}" \
    --deployer-email "${GCP_DEPLOYER_SERVICE_ACCOUNT}" \
    --app-a-gsa-email "${app_a_gsa_email}" \
    --grafana-gsa-email "${grafana_gsa_email}" \
    --global-ipv4-address "${global_ipv4_address}" \
    --cloud-armor-policy-name "${cloud_armor_policy_name}" \
    --bigquery-dataset "${bigquery_dataset}" \
    --tls-certificate-name "${tls_certificate_name}" >/dev/null

  gateway_primary="${temporary_root}/gateway-primary.kubeconfig"
  gateway_secondary="${temporary_root}/gateway-secondary.kubeconfig"
  gateway_config="${temporary_root}/gateway-config.kubeconfig"
  get_gateway_credentials "${PRIMARY_CLUSTER}" "${gateway_primary}"
  get_gateway_credentials "${SECONDARY_CLUSTER}" "${gateway_secondary}"
  get_gateway_credentials "${PRIMARY_CLUSTER}" "${gateway_config}"
}

initialize_report() {
  local mode="$1"
  local started_at

  started_at="$(date -u +'%Y%m%dT%H%M%SZ')"
  mkdir -p "${REPO_ROOT}/artifacts/live"
  report_file="${REPO_ROOT}/artifacts/live/${mode}-${started_at}.txt"
  install -m 0600 /dev/null "${report_file}"
  record "timestamp_utc=${started_at}"
  record "mode=${mode}"
  record "project=${GCP_PROJECT_ID}"
}

assert_three_ready() {
  local kubeconfig="$1"
  local region="$2"
  local application="$3"
  local deployment_json

  deployment_json="$(KUBECONFIG="${kubeconfig}" kubectl -n assessment get \
    "deployment/${application}" -o json)"
  jq -e '
    .spec.replicas == 3 and
    .status.replicas == 3 and
    .status.readyReplicas == 3 and
    .status.updatedReplicas == 3 and
    .status.availableReplicas == 3
  ' <<<"${deployment_json}" >/dev/null ||
    die "${application} does not have exactly three Ready replicas in ${region}."
  KUBECONFIG="${kubeconfig}" kubectl -n assessment rollout status \
    "deployment/${application}" --timeout="${ROLLOUT_TIMEOUT}" >/dev/null
  record "deployment=${application} region=${region} ready=3 desired=3 rollout=successful"
}

http_status() {
  local url="$1"
  curl --silent --show-error --output /dev/null --connect-timeout 10 --max-time 30 \
    --write-out '%{http_code}' "${url}"
}

assert_route_status_class() {
  local scheme="$1"
  local authority="$2"
  local path="$3"
  local expected_pattern="$4"
  local expected_class="$5"
  local code

  code="$(http_status "${scheme}://${authority}${path}")"
  [[ "${code}" =~ ${expected_pattern} ]] || die "${scheme} route ${path} returned HTTP ${code}."
  record "route=${path} scheme=${scheme} status_class=${expected_class} code=${code}"
}

verify_backend_health() {
  local mci_json="$1"
  local backend_services
  local backend_service
  local health_json
  local backend_count=0

  backend_services="$(jq -r '
    (.status.cloudResources.BackendServices //
     .status.cloudResources.backendServices // []) as $services |
    if ($services | type) == "array" then
      $services[]
    elif ($services | type) == "string" then
      $services | split(",")[]
    else
      empty
    end
  ' <<<"${mci_json}")"
  while IFS= read -r backend_service; do
    backend_service="${backend_service//[[:space:]\"]/}"
    [[ -n "${backend_service}" ]] || continue
    backend_count=$((backend_count + 1))
    health_json="$(gcloud compute backend-services get-health "${backend_service}" \
      --global --project="${GCP_PROJECT_ID}" --format=json)"
    jq -e '[.[]?.healthStatus[]?] |
      (length > 0 and all(.healthState == "HEALTHY"))' <<<"${health_json}" >/dev/null ||
      die "Backend service ${backend_service} is not fully HEALTHY."
    record "backend_service=${backend_service} health=HEALTHY"
  done <<<"${backend_services}"
  ((backend_count >= 2)) || die "MultiClusterIngress did not report both backend services."
}

verify_bigquery() {
  local tables_json
  local table_count
  local deadline=$((SECONDS + DRILL_TIMEOUT_SECONDS))
  local query_file
  local query_text
  local -a query_parameters
  local query_count=0

  tables_json='[]'
  table_count=0
  while ((SECONDS < deadline)); do
    if tables_json="$(bq ls --project_id="${GCP_PROJECT_ID}" --format=json \
      "${GCP_PROJECT_ID}:${bigquery_dataset}" 2>/dev/null)"; then
      table_count="$(jq -er 'length' <<<"${tables_json}")"
      if ((table_count > 0)); then
        break
      fi
    fi
    sleep 15
  done
  ((table_count > 0)) || die "BigQuery log dataset is available but has no routed log tables."
  record "bigquery_dataset=${bigquery_dataset} availability=available table_count=${table_count}"

  VERIFY_END_TIME="${VERIFY_END_TIME:-$(date -u +'%Y-%m-%dT%H:%M:%SZ')}"
  VERIFY_START_TIME="${VERIFY_START_TIME:-$(date -u -d '1 hour ago' +'%Y-%m-%dT%H:%M:%SZ')}"
  [[ "${VERIFY_START_TIME}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] ||
    die "VERIFY_START_TIME must be UTC RFC3339 seconds."
  [[ "${VERIFY_END_TIME}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] ||
    die "VERIFY_END_TIME must be UTC RFC3339 seconds."

  for query_file in "${REPO_ROOT}"/observability/bigquery/queries/*.sql; do
    query_count=$((query_count + 1))
    query_text="$(sed -e "s|\${GCP_PROJECT_ID}|${GCP_PROJECT_ID}|g" \
      -e "s|\${BIGQUERY_DATASET}|${bigquery_dataset}|g" "${query_file}")"
    query_parameters=()
    if [[ "${query_file}" != */schema-discovery.sql ]]; then
      query_parameters+=(--parameter=start_time:TIMESTAMP:"${VERIFY_START_TIME}")
      query_parameters+=(--parameter=end_time:TIMESTAMP:"${VERIFY_END_TIME}")
    fi
    bq query --project_id="${GCP_PROJECT_ID}" --dry_run --use_legacy_sql=false \
      "${query_parameters[@]}" "${query_text}" >/dev/null
    record "bigquery_query=$(basename "${query_file}") dry_run=successful"
  done
  [[ ${query_count} -eq 7 ]] || die "Expected exactly seven committed BigQuery SQL files."
}

verify_grafana() {
  local deployment_json
  local configmaps_json
  local dashboard_count

  deployment_json="$(KUBECONFIG="${gateway_primary}" kubectl -n observability get \
    deployment/grafana -o json)"
  jq -e '.spec.replicas == 1 and .status.readyReplicas == 1 and .status.availableReplicas == 1' \
    <<<"${deployment_json}" >/dev/null || die "Grafana health-probe-gated deployment is not Ready."
  configmaps_json="$(KUBECONFIG="${gateway_primary}" kubectl -n observability get configmaps -o json)"
  dashboard_count="$(jq -er '[.items[] |
    select(.metadata.name | startswith("grafana-dashboards-")) |
    .data | keys[] | select(endswith(".json"))] | length' <<<"${configmaps_json}")"
  [[ "${dashboard_count}" == "3" ]] || die "Grafana does not have exactly three provisioned dashboard JSON files."
  record "grafana health=ready dashboard_provisioning=configured dashboard_count=3"
}

smoke_verification() {
  local region
  local cluster
  local membership_status
  local cluster_status
  local mci_json
  local mci_vip
  local mcs_json
  local backend_policy
  local certificate_status

  initialize_context
  initialize_report smoke

  for region in "${PRIMARY_REGION}" "${SECONDARY_REGION}"; do
    if [[ "${region}" == "${PRIMARY_REGION}" ]]; then
      cluster="${PRIMARY_CLUSTER}"
    else
      cluster="${SECONDARY_CLUSTER}"
    fi
    membership_status="$(gcloud container fleet memberships describe "${cluster}" \
      --location=global --project="${GCP_PROJECT_ID}" --format='value(state.code)')"
    [[ "${membership_status}" == "READY" ]] || die "Fleet membership ${cluster} is not READY."
    cluster_status="$(gcloud container clusters describe "${cluster}" --region="${region}" \
      --project="${GCP_PROJECT_ID}" --format='value(status)')"
    [[ "${cluster_status}" == "RUNNING" ]] || die "Cluster ${cluster} is not RUNNING."
    record "fleet_membership=${cluster} status=READY"
    record "cluster=${cluster} region=${region} status=RUNNING"
  done

  assert_three_ready "${gateway_primary}" "${PRIMARY_REGION}" app-a
  assert_three_ready "${gateway_primary}" "${PRIMARY_REGION}" app-b
  assert_three_ready "${gateway_secondary}" "${SECONDARY_REGION}" app-a
  assert_three_ready "${gateway_secondary}" "${SECONDARY_REGION}" app-b

  mci_json="$(KUBECONFIG="${gateway_config}" kubectl -n assessment get \
    multiclusteringress.networking.gke.io/assessment-ingress -o json)"
  mci_vip="$(jq -er '.status.VIP | select(length > 0)' <<<"${mci_json}")"
  [[ "${mci_vip}" == "${global_ipv4_address}" ]] || die "MultiClusterIngress VIP differs from Terraform output."
  record "multicluster_ingress=assessment-ingress vip_status=assigned"

  mcs_json="$(KUBECONFIG="${gateway_config}" kubectl -n assessment get \
    multiclusterservices.networking.gke.io -o json)"
  jq -e '[.items[].metadata.name] | sort == ["app-a-mcs", "app-b-mcs"]' \
    <<<"${mcs_json}" >/dev/null || die "Expected exactly the App A and App B MultiClusterServices."
  record "multicluster_services=app-a-mcs,app-b-mcs status=present"

  for backend_config in app-a-backend app-b-backend; do
    backend_policy="$(KUBECONFIG="${gateway_config}" kubectl -n assessment get \
      "backendconfig.cloud.google.com/${backend_config}" -o jsonpath='{.spec.securityPolicy.name}')"
    [[ "${backend_policy}" == "${cloud_armor_policy_name}" ]] ||
      die "BackendConfig ${backend_config} is not attached to the expected Cloud Armor policy."
    record "backend_config=${backend_config} cloud_armor=attached"
  done
  verify_backend_health "${mci_json}"

  if [[ "${GCP_ENABLE_HTTPS}" == "true" ]]; then
    [[ -n "${tls_certificate_name}" ]] || die "HTTPS enabled without a certificate output."
    require_environment GCP_DNS_NAME
    assert_route_status_class http "${GCP_DNS_NAME}" /app-a '^3[0-9][0-9]$' 3xx
    assert_route_status_class http "${GCP_DNS_NAME}" /app-b '^3[0-9][0-9]$' 3xx
    certificate_status="$(gcloud compute ssl-certificates describe "${tls_certificate_name}" \
      --global --project="${GCP_PROJECT_ID}" --format='value(managed.status)')"
    [[ "${certificate_status}" == "ACTIVE" ]] || die "Managed certificate is not ACTIVE."
    record "managed_certificate=${tls_certificate_name} status=ACTIVE"
    assert_route_status_class https "${GCP_DNS_NAME}" /app-a '^2[0-9][0-9]$' 2xx
    assert_route_status_class https "${GCP_DNS_NAME}" /app-b '^2[0-9][0-9]$' 2xx
  else
    assert_route_status_class http "${global_ipv4_address}" /app-a '^2[0-9][0-9]$' 2xx
    assert_route_status_class http "${global_ipv4_address}" /app-b '^2[0-9][0-9]$' 2xx
  fi

  verify_bigquery
  verify_grafana
  record "completed_at_utc=$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
}

kubeconfig_for_region() {
  case "$1" in
    us-central1) printf '%s\n' "${gateway_primary}" ;;
    us-east1) printf '%s\n' "${gateway_secondary}" ;;
    *) die "Unsupported region: $1" ;;
  esac
}

overlay_for_region() {
  case "$1" in
    us-central1) printf '%s\n' "${REPO_ROOT}/.generated/k8s/overlays/us-central1" ;;
    us-east1) printf '%s\n' "${REPO_ROOT}/.generated/k8s/overlays/us-east1" ;;
    *) die "Unsupported region: $1" ;;
  esac
}

wait_for_hpa_scale() {
  local kubeconfig="$1"
  local deadline=$((SECONDS + DRILL_TIMEOUT_SECONDS))
  local application
  local desired
  local ready
  local scaled

  while ((SECONDS < deadline)); do
    scaled=true
    for application in app-a app-b; do
      desired="$(KUBECONFIG="${kubeconfig}" kubectl -n assessment get "hpa/${application}" \
        -o jsonpath='{.status.desiredReplicas}' 2>/dev/null || true)"
      ready="$(KUBECONFIG="${kubeconfig}" kubectl -n assessment get "deployment/${application}" \
        -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)"
      if [[ ! "${desired}" =~ ^[0-9]+$ || ! "${ready}" =~ ^[0-9]+$ ]] ||
        ((desired < 4 || ready < 4)); then
        scaled=false
      fi
    done
    if [[ "${scaled}" == "true" ]]; then
      return 0
    fi
    sleep 10
  done
  return 1
}

hpa_drill() {
  local region="$1"
  local confirmation="$2"
  local kubeconfig
  local application

  [[ "${confirmation}" == "HPA ${region}" ]] || die "HPA confirmation must be exactly: HPA ${region}"
  initialize_context
  initialize_report hpa
  kubeconfig="$(kubeconfig_for_region "${region}")"
  RESTORE_KUBECONFIG="${kubeconfig}"
  RESTORE_OVERLAY="$(overlay_for_region "${region}")"
  record "exercise=controlled-application-hpa region=${region} claim_scope=application-only"
  assert_three_ready "${kubeconfig}" "${region}" app-a
  assert_three_ready "${kubeconfig}" "${region}" app-b

  for application in app-a app-b; do
    KUBECONFIG="${kubeconfig}" kubectl -n assessment patch "hpa/${application}" \
      --type=merge -p '{"spec":{"minReplicas":4}}' >/dev/null
  done
  wait_for_hpa_scale "${kubeconfig}" || die "HPA controllers did not reach four Ready replicas before timeout."
  record "hpa=app-a,app-b desired_replicas_at_least=4 ready_replicas_at_least=4 status=successful"

  restore_committed_workloads || die "Failed to restore committed workloads after HPA exercise."
  RESTORE_KUBECONFIG=""
  RESTORE_OVERLAY=""
  record "restoration=committed-workloads status=successful"
  record "completed_at_utc=$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
}

wait_for_routes() {
  local deadline=$((SECONDS + DRILL_TIMEOUT_SECONDS))
  local scheme=http
  local authority="${global_ipv4_address}"
  local code_a
  local code_b
  local consecutive_successes=0

  if [[ "${GCP_ENABLE_HTTPS}" == "true" ]]; then
    require_environment GCP_DNS_NAME
    scheme=https
    authority="${GCP_DNS_NAME}"
  fi
  while ((SECONDS < deadline)); do
    code_a="$(http_status "${scheme}://${authority}/app-a" || true)"
    code_b="$(http_status "${scheme}://${authority}/app-b" || true)"
    if [[ "${code_a}" =~ ^2[0-9][0-9]$ && "${code_b}" =~ ^2[0-9][0-9]$ ]]; then
      consecutive_successes=$((consecutive_successes + 1))
      if ((consecutive_successes >= 5)); then
        record "route=/app-a exercise_status_class=2xx code=${code_a} consecutive_checks=5"
        record "route=/app-b exercise_status_class=2xx code=${code_b} consecutive_checks=5"
        return 0
      fi
    else
      consecutive_successes=0
    fi
    sleep 5
  done
  return 1
}

failover_drill() {
  local region="$1"
  local confirmation="$2"
  local target_kubeconfig
  local remaining_kubeconfig
  local remaining_region

  [[ "${confirmation}" == "FAILOVER ${region}" ]] ||
    die "Failover confirmation must be exactly: FAILOVER ${region}"
  initialize_context
  initialize_report failover
  target_kubeconfig="$(kubeconfig_for_region "${region}")"
  if [[ "${region}" == "${PRIMARY_REGION}" ]]; then
    remaining_kubeconfig="${gateway_secondary}"
    remaining_region="${SECONDARY_REGION}"
  else
    remaining_kubeconfig="${gateway_primary}"
    remaining_region="${PRIMARY_REGION}"
  fi
  assert_three_ready "${target_kubeconfig}" "${region}" app-a
  assert_three_ready "${target_kubeconfig}" "${region}" app-b
  assert_three_ready "${remaining_kubeconfig}" "${remaining_region}" app-a
  assert_three_ready "${remaining_kubeconfig}" "${remaining_region}" app-b

  RESTORE_KUBECONFIG="${target_kubeconfig}"
  RESTORE_OVERLAY="$(overlay_for_region "${region}")"
  record "exercise=controlled-application-failover region=${region} claim_scope=application-only"
  KUBECONFIG="${target_kubeconfig}" kubectl -n assessment delete deployment app-a app-b \
    --wait=true --timeout="${ROLLOUT_TIMEOUT}" >/dev/null
  record "applications=app-a,app-b region=${region} availability=deliberately-removed"
  wait_for_routes || die "Global HTTP routes did not remain successful during the application exercise."

  restore_committed_workloads || die "Failed to restore committed workloads after failover exercise."
  RESTORE_KUBECONFIG=""
  RESTORE_OVERLAY=""
  record "restoration=committed-workloads status=successful"
  record "completed_at_utc=$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
}

parse_drill_arguments() {
  local mode="$1"
  shift
  local region=""
  local confirmation=""

  while (($# > 0)); do
    case "$1" in
      --region)
        [[ -n "${2-}" ]] || die "--region requires a value."
        region="$2"
        shift 2
        ;;
      --confirm)
        [[ -n "${2-}" ]] || die "--confirm requires a value."
        confirmation="$2"
        shift 2
        ;;
      *)
        usage >&2
        die "Unknown ${mode} argument: $1"
        ;;
    esac
  done
  [[ "${region}" == "${PRIMARY_REGION}" || "${region}" == "${SECONDARY_REGION}" ]] ||
    die "--region must be ${PRIMARY_REGION} or ${SECONDARY_REGION}."

  if [[ "${mode}" == "hpa" ]]; then
    hpa_drill "${region}" "${confirmation}"
  else
    failover_drill "${region}" "${confirmation}"
  fi
}

[[ $# -ge 1 ]] || {
  usage >&2
  exit 2
}

mode="$1"
shift
case "${mode}" in
  smoke)
    [[ $# -eq 0 ]] || die "smoke accepts no arguments."
    smoke_verification
    ;;
  hpa|failover)
    parse_drill_arguments "${mode}" "$@"
    ;;
  *)
    usage >&2
    die "Unknown verification mode: ${mode}"
    ;;
esac
