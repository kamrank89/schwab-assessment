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
RECONCILE_TIMEOUT_SECONDS=1200
CERTIFICATE_TIMEOUT_SECONDS=2700

usage() {
  cat <<'USAGE'
Usage: deploy.sh foundation|platform|workloads|https-to-http

Required environment variables:
  GCP_PROJECT_ID GCP_PROJECT_NUMBER GCP_DEPLOYER_SERVICE_ACCOUNT GCP_CLUSTER_ADMIN_EMAIL
  TF_STATE_BUCKET GCP_REGION_PRIMARY GCP_REGION_SECONDARY
  GCP_ENABLE_HTTPS GCP_MANAGE_DNS GCP_CREATE_DNS_ZONE
  GCP_DNS_NAME GCP_DNS_ZONE_NAME GCP_DNS_ZONE_DNS_NAME
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

validate_common_environment() {
  require_environment GCP_PROJECT_ID
  require_environment GCP_CLUSTER_ADMIN_EMAIL
  require_environment TF_STATE_BUCKET
  require_environment GCP_REGION_PRIMARY
  require_environment GCP_REGION_SECONDARY
  require_environment GCP_ENABLE_HTTPS
  require_environment GCP_MANAGE_DNS
  require_environment GCP_CREATE_DNS_ZONE

  [[ "${GCP_PROJECT_ID}" =~ ^[a-z][a-z0-9-]{4,28}[a-z0-9]$ ]] || die "Invalid GCP_PROJECT_ID."
  [[ "${GCP_CLUSTER_ADMIN_EMAIL}" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]] ||
    die "Invalid GCP_CLUSTER_ADMIN_EMAIL."
  [[ "${TF_STATE_BUCKET}" =~ ^[a-z0-9][a-z0-9._-]{1,61}[a-z0-9]$ ]] || die "Invalid TF_STATE_BUCKET."
  [[ "${GCP_REGION_PRIMARY}" == "${PRIMARY_REGION}" ]] || die "GCP_REGION_PRIMARY must be ${PRIMARY_REGION}."
  [[ "${GCP_REGION_SECONDARY}" == "${SECONDARY_REGION}" ]] || die "GCP_REGION_SECONDARY must be ${SECONDARY_REGION}."
  for boolean_name in GCP_ENABLE_HTTPS GCP_MANAGE_DNS GCP_CREATE_DNS_ZONE; do
    [[ "${!boolean_name}" == "true" || "${!boolean_name}" == "false" ]] ||
      die "${boolean_name} must be true or false."
  done
  if [[ "${GCP_ENABLE_HTTPS}" == "true" || "${GCP_MANAGE_DNS}" == "true" ]]; then
    [[ "${GCP_DNS_NAME:-}" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] ||
      die "GCP_DNS_NAME must be a hostname when HTTPS or DNS management is enabled."
  fi
  if [[ "${GCP_MANAGE_DNS}" == "true" ]]; then
    [[ "${GCP_DNS_ZONE_NAME:-}" =~ ^[a-z]([a-z0-9-]{0,61}[a-z0-9])?$ ]] ||
      die "GCP_DNS_ZONE_NAME is invalid."
  fi
  if [[ "${GCP_CREATE_DNS_ZONE}" == "true" ]]; then
    [[ "${GCP_MANAGE_DNS}" == "true" ]] || die "GCP_CREATE_DNS_ZONE=true requires GCP_MANAGE_DNS=true."
    [[ "${GCP_DNS_ZONE_DNS_NAME:-}" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+$ ]] ||
      die "GCP_DNS_ZONE_DNS_NAME must be a trailing-dot DNS suffix."
  fi
}

temporary_root=""
cleanup() {
  if [[ -n "${temporary_root}" ]]; then
    rm -rf -- "${temporary_root}"
  fi
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

new_temporary_root() {
  temporary_root="$(mktemp -d "${TMPDIR:-/tmp}/gke-assessment-deploy.XXXXXX")"
  chmod 0700 "${temporary_root}"
}

terraform_deploy() {
  local stage="$1"
  local terraform_root="${REPO_ROOT}/infra/${stage}"
  local plan_file
  local plan_summary
  local -a variable_arguments

  [[ "${stage}" == "foundation" || "${stage}" == "platform" ]] || die "Refusing unexpected Terraform root: ${stage}"
  [[ -d "${terraform_root}" ]] || die "Terraform root is missing: ${terraform_root}"
  require_command terraform
  require_command jq
  validate_common_environment
  new_temporary_root
  plan_file="${temporary_root}/${stage}.tfplan"

  variable_arguments=(-var="terraform_state_bucket=${TF_STATE_BUCKET}")
  if [[ "${stage}" == "foundation" ]]; then
    variable_arguments+=(
      -var="cluster_admin_email=${GCP_CLUSTER_ADMIN_EMAIL}"
      -var="enable_https=${GCP_ENABLE_HTTPS}"
      -var="manage_dns=${GCP_MANAGE_DNS}"
      -var="create_dns_zone=${GCP_CREATE_DNS_ZONE}"
      -var="dns_name=${GCP_DNS_NAME:-}"
      -var="dns_zone_name=${GCP_DNS_ZONE_NAME:-}"
      -var="dns_zone_dns_name=${GCP_DNS_ZONE_DNS_NAME:-}"
    )
  fi

  terraform -chdir="${terraform_root}" init -input=false -reconfigure \
    -backend-config="bucket=${TF_STATE_BUCKET}" \
    -backend-config="prefix=${stage}"
  terraform -chdir="${terraform_root}" plan -input=false \
    -out="${plan_file}" "${variable_arguments[@]}" >/dev/null
  chmod 0600 "${plan_file}"

  plan_summary="$(terraform -chdir="${terraform_root}" show -json "${plan_file}" |
    jq -r '.resource_changes[]? |
      select(.change.actions != ["no-op"]) |
      [.address, (.change.actions | join(","))] | @tsv')"
  printf 'Terraform %s plan actions (resource address and action type only):\n' "${stage}"
  if [[ -n "${plan_summary}" ]]; then
    printf '%s\n' "${plan_summary}"
  else
    printf '%s\n' 'No resource changes.'
  fi

  terraform -chdir="${terraform_root}" apply -input=false -auto-approve "${plan_file}"
  rm -f -- "${plan_file}"
  rmdir "${temporary_root}"
  temporary_root=""
}

prepare_kubeconfig() {
  local path="$1"
  install -m 0600 /dev/null "${path}"
}

get_dns_credentials() {
  local cluster="$1"
  local region="$2"
  local kubeconfig="$3"

  prepare_kubeconfig "${kubeconfig}"
  KUBECONFIG="${kubeconfig}" gcloud container clusters get-credentials "${cluster}" \
    --region="${region}" --project="${GCP_PROJECT_ID}" --dns-endpoint --quiet >/dev/null
  chmod 0600 "${kubeconfig}"
}

get_gateway_credentials() {
  local membership="$1"
  local kubeconfig="$2"

  prepare_kubeconfig "${kubeconfig}"
  KUBECONFIG="${kubeconfig}" gcloud container fleet memberships get-credentials "${membership}" \
    --location=global --project="${GCP_PROJECT_ID}" --quiet >/dev/null
  chmod 0600 "${kubeconfig}"
}

apply_overlay() {
  local kubeconfig="$1"
  local overlay="$2"

  [[ -d "${overlay}" ]] || die "Kustomize overlay is missing: ${overlay}"
  kustomize build "${overlay}" | KUBECONFIG="${kubeconfig}" kubectl apply -f -
}

ensure_initial_secret_version() {
  local secret_id="$1"
  local existing_version

  existing_version="$(gcloud secrets versions list "${secret_id}" \
    --project="${GCP_PROJECT_ID}" --filter='state=ENABLED' --limit=1 --format='value(name)' 2>/dev/null)"
  if [[ -z "${existing_version}" ]]; then
    openssl rand -base64 48 |
      gcloud secrets versions add "${secret_id}" --project="${GCP_PROJECT_ID}" \
        --data-file=- --quiet >/dev/null
    printf 'Created the initial version for Secret Manager container %s.\n' "${secret_id}"
  else
    printf 'Secret Manager container %s already has an enabled version; no value was changed.\n' "${secret_id}"
  fi
}

wait_for_rollout() {
  local kubeconfig="$1"
  local namespace="$2"
  local deployment="$3"

  KUBECONFIG="${kubeconfig}" kubectl -n "${namespace}" rollout status \
    "deployment/${deployment}" --timeout="${ROLLOUT_TIMEOUT}"
}

wait_for_mci_vip() {
  local kubeconfig="$1"
  local expected_vip="$2"
  local deadline=$((SECONDS + RECONCILE_TIMEOUT_SECONDS))
  local actual_vip

  while ((SECONDS < deadline)); do
    actual_vip="$(KUBECONFIG="${kubeconfig}" kubectl -n assessment get \
      multiclusteringress.networking.gke.io assessment-ingress \
      -o jsonpath='{.status.VIP}' 2>/dev/null || true)"
    if [[ "${actual_vip}" == "${expected_vip}" ]]; then
      printf 'MultiClusterIngress reconciled to the reserved global IPv4 address.\n'
      return 0
    fi
    sleep 15
  done
  die "MultiClusterIngress did not reconcile before the bounded timeout."
}

wait_for_certificate() {
  local certificate_name="$1"
  local deadline=$((SECONDS + CERTIFICATE_TIMEOUT_SECONDS))
  local status

  while ((SECONDS < deadline)); do
    status="$(gcloud compute ssl-certificates describe "${certificate_name}" \
      --global --project="${GCP_PROJECT_ID}" --format='value(managed.status)' 2>/dev/null || true)"
    if [[ "${status}" == "ACTIVE" ]]; then
      printf 'Managed certificate %s is ACTIVE.\n' "${certificate_name}"
      return 0
    fi
    sleep 30
  done
  die "Managed certificate did not become ACTIVE before the bounded timeout."
}

route_status_code() {
  local url="$1"

  curl --silent --show-error --output /dev/null --connect-timeout 10 --max-time 30 \
    --write-out '%{http_code}' "${url}"
}

wait_for_http_reconciliation() {
  local authority="$1"
  local deadline=$((SECONDS + RECONCILE_TIMEOUT_SECONDS))
  local http_app_a
  local http_app_b

  while ((SECONDS < deadline)); do
    http_app_a="$(route_status_code "http://${authority}/app-a" || true)"
    http_app_b="$(route_status_code "http://${authority}/app-b" || true)"
    if [[ "${http_app_a}" =~ ^2[0-9][0-9]$ && "${http_app_b}" =~ ^2[0-9][0-9]$ ]]; then
      printf '%s\n' 'HTTP routing reconciled: both application routes return 2xx.'
      return 0
    fi
    sleep 15
  done
  die "HTTP application routes did not reconcile before the bounded timeout."
}

wait_for_https_reconciliation() {
  local deadline=$((SECONDS + RECONCILE_TIMEOUT_SECONDS))
  local http_app_a
  local http_app_b
  local https_app_a
  local https_app_b

  while ((SECONDS < deadline)); do
    http_app_a="$(route_status_code "http://${GCP_DNS_NAME}/app-a" || true)"
    http_app_b="$(route_status_code "http://${GCP_DNS_NAME}/app-b" || true)"
    https_app_a="$(route_status_code "https://${GCP_DNS_NAME}/app-a" || true)"
    https_app_b="$(route_status_code "https://${GCP_DNS_NAME}/app-b" || true)"
    if [[ "${http_app_a}" =~ ^3[0-9][0-9]$ &&
      "${http_app_b}" =~ ^3[0-9][0-9]$ &&
      "${https_app_a}" =~ ^2[0-9][0-9]$ &&
      "${https_app_b}" =~ ^2[0-9][0-9]$ ]]; then
      printf '%s\n' 'HTTPS routing reconciled: HTTP redirects and HTTPS application routes are healthy.'
      return 0
    fi
    sleep 15
  done
  die "HTTPS redirect and application routes did not reconcile before the bounded timeout."
}

wait_for_certificate_detachment() {
  local kubeconfig="$1"
  local certificate_name="$2"
  local deadline=$((SECONDS + RECONCILE_TIMEOUT_SECONDS))
  local mci_json
  local https_proxies_json
  local ssl_proxies_json
  local reference_count

  while ((SECONDS < deadline)); do
    if ! mci_json="$(KUBECONFIG="${kubeconfig}" kubectl -n assessment get \
      multiclusteringress.networking.gke.io/assessment-ingress -o json 2>/dev/null)"; then
      die "Could not inspect MultiClusterIngress during the HTTPS-to-HTTP transition."
    fi
    jq -e '
      .metadata.namespace == "assessment" and
      .metadata.name == "assessment-ingress" and
      ((.metadata.annotations // {}) | type) == "object"
    ' <<<"${mci_json}" >/dev/null ||
      die "MultiClusterIngress metadata is malformed during the HTTPS-to-HTTP transition."
    if jq -e '
      (.metadata.annotations // {}) as $annotations |
      (($annotations | has("networking.gke.io/pre-shared-certs")) | not) and
      (($annotations | has("networking.gke.io/frontend-config")) | not)
    ' <<<"${mci_json}" >/dev/null; then
      if ! https_proxies_json="$(gcloud compute target-https-proxies list --global \
        --project="${GCP_PROJECT_ID}" --format=json 2>/dev/null)"; then
        die "Could not inspect target HTTPS proxies while proving certificate detachment."
      fi
      if ! ssl_proxies_json="$(gcloud compute target-ssl-proxies list \
        --project="${GCP_PROJECT_ID}" --format=json 2>/dev/null)"; then
        die "Could not inspect target SSL proxies while proving certificate detachment."
      fi
      jq -e '
        type == "array" and
        all(.[];
          type == "object" and
          ((has("sslCertificates") | not) or
           .sslCertificates == null or
           ((.sslCertificates | type) == "array" and
            all(.sslCertificates[]; type == "string")))
        )
      ' <<<"${https_proxies_json}" >/dev/null ||
        die "Target HTTPS proxy inventory is malformed."
      jq -e '
        type == "array" and
        all(.[];
          type == "object" and
          ((has("sslCertificates") | not) or
           .sslCertificates == null or
           ((.sslCertificates | type) == "array" and
            all(.sslCertificates[]; type == "string")))
        )
      ' <<<"${ssl_proxies_json}" >/dev/null ||
        die "Target SSL proxy inventory is malformed."
      reference_count="$(jq -ner --arg certificate "${certificate_name}" \
        --argjson https "${https_proxies_json}" --argjson ssl "${ssl_proxies_json}" '
          [$https[], $ssl[]] |
          [.[] | .sslCertificates[]? |
            sub("\\?.*$"; "") | split("/") | last |
            select(. == $certificate)] |
          length
        ')"
      if [[ "${reference_count}" == "0" ]]; then
        printf 'HTTPS-to-HTTP transition reconciled: MCI TLS/frontend annotations are absent and certificate %s is not referenced by any target HTTPS or SSL proxy.\n' \
          "${certificate_name}"
        return 0
      fi
    fi
    sleep 15
  done
  die "Managed certificate remained referenced by MCI or a target proxy after the bounded HTTPS-to-HTTP transition timeout."
}

transition_https_to_http() {
  local foundation_json
  local platform_json
  local app_a_gsa_email
  local grafana_gsa_email
  local cluster_admin_email
  local global_ipv4_address
  local cloud_armor_policy_name
  local bigquery_dataset
  local foundation_tls_certificate_name
  local platform_tls_certificate_name
  local tls_certificate_name
  local render_root="${REPO_ROOT}/.generated/k8s"
  local gateway_config

  for command_name in terraform jq gcloud kubectl kustomize curl; do
    require_command "${command_name}"
  done
  validate_common_environment
  require_environment GCP_PROJECT_NUMBER
  require_environment GCP_DEPLOYER_SERVICE_ACCOUNT
  [[ "${GCP_PROJECT_NUMBER}" =~ ^[1-9][0-9]{5,19}$ ]] || die "Invalid GCP_PROJECT_NUMBER."
  [[ "${GCP_DEPLOYER_SERVICE_ACCOUNT}" =~ ^[a-z][a-z0-9-]{4,28}[a-z0-9]@[a-z][a-z0-9-]{4,28}[a-z0-9]\.iam\.gserviceaccount\.com$ ]] ||
    die "Invalid GCP_DEPLOYER_SERVICE_ACCOUNT."
  [[ "${GCP_ENABLE_HTTPS}:${GCP_MANAGE_DNS}:${GCP_CREATE_DNS_ZONE}" == "false:false:false" ]] ||
    die "https-to-http requires GCP_ENABLE_HTTPS, GCP_MANAGE_DNS, and GCP_CREATE_DNS_ZONE to all be false."

  terraform -chdir="${REPO_ROOT}/infra/foundation" init -input=false -reconfigure \
    -backend-config="bucket=${TF_STATE_BUCKET}" -backend-config="prefix=foundation" >/dev/null
  foundation_json="$(terraform -chdir="${REPO_ROOT}/infra/foundation" output -json)"
  foundation_tls_certificate_name="$(jq -er \
    '.tls_certificate_name.value | select(type == "string" and length > 0)' \
    <<<"${foundation_json}")" ||
    die "https-to-http requires the still-present foundation state to expose the managed certificate name."

  terraform -chdir="${REPO_ROOT}/infra/platform" init -input=false -reconfigure \
    -backend-config="bucket=${TF_STATE_BUCKET}" -backend-config="prefix=platform" >/dev/null
  platform_json="$(terraform -chdir="${REPO_ROOT}/infra/platform" output -json)"
  cluster_admin_email="$(jq -er '.cluster_admin_email.value |
    select(type == "string" and test("^[^@[:space:]]+@[^@[:space:]]+\\.[^@[:space:]]+$"))' \
    <<<"${platform_json}")" || die "Platform cluster administrator email output is missing or invalid."
  [[ "${cluster_admin_email}" == "${GCP_CLUSTER_ADMIN_EMAIL,,}" ]] ||
    die "Platform cluster administrator email differs from GCP_CLUSTER_ADMIN_EMAIL."
  app_a_gsa_email="$(jq -er '.app_a_runtime_gsa_email.value' <<<"${platform_json}")"
  grafana_gsa_email="$(jq -er '.grafana_runtime_gsa_email.value' <<<"${platform_json}")"
  global_ipv4_address="$(jq -er '.global_ipv4_address.value' <<<"${platform_json}")"
  cloud_armor_policy_name="$(jq -er '.cloud_armor_policy_name.value' <<<"${platform_json}")"
  bigquery_dataset="$(jq -er '.bigquery_dataset_id.value' <<<"${platform_json}")"
  platform_tls_certificate_name="$(jq -er '.tls_certificate_name.value | select(type == "string" and length > 0)' \
    <<<"${platform_json}")" ||
    die "https-to-http requires the still-present platform state to expose the managed certificate name."
  [[ "${platform_tls_certificate_name}" == "${foundation_tls_certificate_name}" ]] ||
    die "Foundation and platform state disagree on the managed certificate; refusing the transition."
  tls_certificate_name="${foundation_tls_certificate_name}"

  "${SCRIPT_DIR}/render-manifests.sh" \
    --project-id "${GCP_PROJECT_ID}" \
    --project-number "${GCP_PROJECT_NUMBER}" \
    --deployer-email "${GCP_DEPLOYER_SERVICE_ACCOUNT}" \
    --cluster-admin-email "${cluster_admin_email}" \
    --app-a-gsa-email "${app_a_gsa_email}" \
    --grafana-gsa-email "${grafana_gsa_email}" \
    --global-ipv4-address "${global_ipv4_address}" \
    --cloud-armor-policy-name "${cloud_armor_policy_name}" \
    --bigquery-dataset "${bigquery_dataset}" \
    --tls-certificate-name "${tls_certificate_name}"

  new_temporary_root
  gateway_config="${temporary_root}/gateway-config.kubeconfig"
  get_gateway_credentials "${PRIMARY_CLUSTER}" "${gateway_config}"
  apply_overlay "${gateway_config}" "${render_root}/overlays/config-us-central1/http"
  wait_for_mci_vip "${gateway_config}" "${global_ipv4_address}"
  wait_for_http_reconciliation "${global_ipv4_address}"
  wait_for_certificate_detachment "${gateway_config}" "${tls_certificate_name}"
  printf '%s\n' 'HTTPS-to-HTTP preparation completed without foundation or platform Terraform mutation. Run one ordinary deploy dispatch next.'
}

deploy_workloads() {
  local platform_json
  local app_a_gsa_email
  local grafana_gsa_email
  local cluster_admin_email
  local global_ipv4_address
  local cloud_armor_policy_name
  local bigquery_dataset
  local app_a_secret_id
  local grafana_secret_id
  local tls_certificate_name
  local render_root="${REPO_ROOT}/.generated/k8s"
  local dns_primary
  local dns_secondary
  local gateway_primary
  local gateway_secondary
  local gateway_config

  for command_name in terraform jq gcloud kubectl kustomize openssl curl; do
    require_command "${command_name}"
  done
  validate_common_environment
  require_environment GCP_PROJECT_NUMBER
  require_environment GCP_DEPLOYER_SERVICE_ACCOUNT
  [[ "${GCP_PROJECT_NUMBER}" =~ ^[1-9][0-9]{5,19}$ ]] || die "Invalid GCP_PROJECT_NUMBER."
  [[ "${GCP_DEPLOYER_SERVICE_ACCOUNT}" =~ ^[a-z][a-z0-9-]{4,28}[a-z0-9]@[a-z][a-z0-9-]{4,28}[a-z0-9]\.iam\.gserviceaccount\.com$ ]] ||
    die "Invalid GCP_DEPLOYER_SERVICE_ACCOUNT."

  terraform -chdir="${REPO_ROOT}/infra/platform" init -input=false -reconfigure \
    -backend-config="bucket=${TF_STATE_BUCKET}" -backend-config="prefix=platform" >/dev/null
  platform_json="$(terraform -chdir="${REPO_ROOT}/infra/platform" output -json)"
  cluster_admin_email="$(jq -er '.cluster_admin_email.value |
    select(type == "string" and test("^[^@[:space:]]+@[^@[:space:]]+\\.[^@[:space:]]+$"))' \
    <<<"${platform_json}")" || die "Platform cluster administrator email output is missing or invalid."
  [[ "${cluster_admin_email}" == "${GCP_CLUSTER_ADMIN_EMAIL,,}" ]] ||
    die "Platform cluster administrator email differs from GCP_CLUSTER_ADMIN_EMAIL."
  app_a_gsa_email="$(jq -er '.app_a_runtime_gsa_email.value' <<<"${platform_json}")"
  grafana_gsa_email="$(jq -er '.grafana_runtime_gsa_email.value' <<<"${platform_json}")"
  global_ipv4_address="$(jq -er '.global_ipv4_address.value' <<<"${platform_json}")"
  cloud_armor_policy_name="$(jq -er '.cloud_armor_policy_name.value' <<<"${platform_json}")"
  bigquery_dataset="$(jq -er '.bigquery_dataset_id.value' <<<"${platform_json}")"
  app_a_secret_id="$(jq -er '.app_a_secret_id.value' <<<"${platform_json}")"
  grafana_secret_id="$(jq -er '.grafana_admin_secret_id.value' <<<"${platform_json}")"
  tls_certificate_name="$(jq -r '.tls_certificate_name.value // ""' <<<"${platform_json}")"
  if [[ "${GCP_ENABLE_HTTPS}" == "true" && -z "${tls_certificate_name}" ]]; then
    die "HTTPS is enabled but Terraform did not expose a managed certificate name."
  fi

  "${SCRIPT_DIR}/render-manifests.sh" \
    --project-id "${GCP_PROJECT_ID}" \
    --project-number "${GCP_PROJECT_NUMBER}" \
    --deployer-email "${GCP_DEPLOYER_SERVICE_ACCOUNT}" \
    --cluster-admin-email "${cluster_admin_email}" \
    --app-a-gsa-email "${app_a_gsa_email}" \
    --grafana-gsa-email "${grafana_gsa_email}" \
    --global-ipv4-address "${global_ipv4_address}" \
    --cloud-armor-policy-name "${cloud_armor_policy_name}" \
    --bigquery-dataset "${bigquery_dataset}" \
    --tls-certificate-name "${tls_certificate_name}"

  ensure_initial_secret_version "${app_a_secret_id}"
  ensure_initial_secret_version "${grafana_secret_id}"

  new_temporary_root
  dns_primary="${temporary_root}/dns-primary.kubeconfig"
  dns_secondary="${temporary_root}/dns-secondary.kubeconfig"
  gateway_primary="${temporary_root}/gateway-primary.kubeconfig"
  gateway_secondary="${temporary_root}/gateway-secondary.kubeconfig"
  gateway_config="${temporary_root}/gateway-config.kubeconfig"

  get_dns_credentials "${PRIMARY_CLUSTER}" "${PRIMARY_REGION}" "${dns_primary}"
  apply_overlay "${dns_primary}" "${render_root}/base/namespace"
  apply_overlay "${dns_primary}" "${render_root}/access/us-central1"
  apply_overlay "${dns_primary}" "${render_root}/access/config-us-central1"

  get_dns_credentials "${SECONDARY_CLUSTER}" "${SECONDARY_REGION}" "${dns_secondary}"
  apply_overlay "${dns_secondary}" "${render_root}/base/namespace"
  apply_overlay "${dns_secondary}" "${render_root}/access/us-east1"

  get_gateway_credentials "${PRIMARY_CLUSTER}" "${gateway_primary}"
  get_gateway_credentials "${SECONDARY_CLUSTER}" "${gateway_secondary}"
  get_gateway_credentials "${PRIMARY_CLUSTER}" "${gateway_config}"

  apply_overlay "${gateway_primary}" "${render_root}/overlays/us-central1"
  apply_overlay "${gateway_secondary}" "${render_root}/overlays/us-east1"

  wait_for_rollout "${gateway_primary}" assessment app-a
  wait_for_rollout "${gateway_primary}" assessment app-b
  wait_for_rollout "${gateway_primary}" observability grafana
  wait_for_rollout "${gateway_secondary}" assessment app-a
  wait_for_rollout "${gateway_secondary}" assessment app-b

  apply_overlay "${gateway_config}" "${render_root}/overlays/config-us-central1/http"
  wait_for_mci_vip "${gateway_config}" "${global_ipv4_address}"

  if [[ "${GCP_ENABLE_HTTPS}" == "true" ]]; then
    apply_overlay "${gateway_config}" "${render_root}/overlays/config-us-central1/tls"
    wait_for_certificate "${tls_certificate_name}"
    apply_overlay "${gateway_config}" "${render_root}/overlays/config-us-central1/https"
    wait_for_https_reconciliation
  fi

  printf '%s\n' 'Workload deployment and bounded reconciliation checks completed.'
}

[[ $# -eq 1 ]] || {
  usage >&2
  exit 2
}

case "$1" in
  foundation|platform)
    terraform_deploy "$1"
    ;;
  workloads)
    deploy_workloads
    ;;
  https-to-http)
    transition_https_to_http
    ;;
  *)
    usage >&2
    die "Unknown deployment stage: $1"
    ;;
esac
