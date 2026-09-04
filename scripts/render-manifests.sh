#!/usr/bin/env bash
set -euo pipefail

umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd -P)"
OUTPUT_DIR="${REPO_ROOT}/.generated/k8s"

usage() {
  cat <<'USAGE'
Usage: render-manifests.sh \
  --project-id ID --project-number NUMBER \
  --deployer-email EMAIL --app-a-gsa-email EMAIL \
  --grafana-gsa-email EMAIL --global-ipv4-address ADDRESS \
  --cloud-armor-policy-name NAME --bigquery-dataset DATASET \
  --cluster-admin-email EMAIL \
  [--tls-certificate-name NAME]

Renders the approved Kubernetes tokens into .generated/k8s.
USAGE
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

require_value() {
  local option="$1"
  local value="${2-}"

  [[ -n "${value}" ]] || die "${option} requires a non-empty value."
}

GCP_PROJECT_ID=""
GCP_PROJECT_NUMBER=""
ASSESSMENT_DEPLOYER_EMAIL=""
ASSESSMENT_CLUSTER_ADMIN_EMAIL=""
APP_A_GSA_EMAIL=""
GRAFANA_GSA_EMAIL=""
GLOBAL_IPV4_ADDRESS=""
CLOUD_ARMOR_POLICY_NAME=""
BIGQUERY_DATASET=""
TLS_CERTIFICATE_NAME=""

while (($# > 0)); do
  case "$1" in
    --project-id)
      require_value "$1" "${2-}"
      GCP_PROJECT_ID="$2"
      shift 2
      ;;
    --project-number)
      require_value "$1" "${2-}"
      GCP_PROJECT_NUMBER="$2"
      shift 2
      ;;
    --deployer-email)
      require_value "$1" "${2-}"
      ASSESSMENT_DEPLOYER_EMAIL="$2"
      shift 2
      ;;
    --cluster-admin-email)
      require_value "$1" "${2-}"
      ASSESSMENT_CLUSTER_ADMIN_EMAIL="$2"
      shift 2
      ;;
    --app-a-gsa-email)
      require_value "$1" "${2-}"
      APP_A_GSA_EMAIL="$2"
      shift 2
      ;;
    --grafana-gsa-email)
      require_value "$1" "${2-}"
      GRAFANA_GSA_EMAIL="$2"
      shift 2
      ;;
    --global-ipv4-address)
      require_value "$1" "${2-}"
      GLOBAL_IPV4_ADDRESS="$2"
      shift 2
      ;;
    --cloud-armor-policy-name)
      require_value "$1" "${2-}"
      CLOUD_ARMOR_POLICY_NAME="$2"
      shift 2
      ;;
    --bigquery-dataset)
      require_value "$1" "${2-}"
      BIGQUERY_DATASET="$2"
      shift 2
      ;;
    --tls-certificate-name)
      (($# >= 2)) || die "$1 requires a value (which may be empty)."
      TLS_CERTIFICATE_NAME="${2-}"
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

[[ "${GCP_PROJECT_ID}" =~ ^[a-z][a-z0-9-]{4,28}[a-z0-9]$ ]] ||
  die "--project-id is not a valid Google Cloud project ID."
[[ "${GCP_PROJECT_NUMBER}" =~ ^[1-9][0-9]{5,19}$ ]] ||
  die "--project-number must be a numeric Google Cloud project number."
[[ "${ASSESSMENT_DEPLOYER_EMAIL}" =~ ^[a-z][a-z0-9-]{4,28}[a-z0-9]@[a-z][a-z0-9-]{4,28}[a-z0-9]\.iam\.gserviceaccount\.com$ ]] ||
  die "--deployer-email is not a valid service-account email."
[[ "${ASSESSMENT_CLUSTER_ADMIN_EMAIL}" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]] ||
  die "--cluster-admin-email is not a valid Google user email."
ASSESSMENT_CLUSTER_ADMIN_EMAIL="${ASSESSMENT_CLUSTER_ADMIN_EMAIL,,}"
[[ "${APP_A_GSA_EMAIL}" =~ ^[a-z][a-z0-9-]{4,28}[a-z0-9]@[a-z][a-z0-9-]{4,28}[a-z0-9]\.iam\.gserviceaccount\.com$ ]] ||
  die "--app-a-gsa-email is not a valid service-account email."
[[ "${GRAFANA_GSA_EMAIL}" =~ ^[a-z][a-z0-9-]{4,28}[a-z0-9]@[a-z][a-z0-9-]{4,28}[a-z0-9]\.iam\.gserviceaccount\.com$ ]] ||
  die "--grafana-gsa-email is not a valid service-account email."
[[ "${CLOUD_ARMOR_POLICY_NAME}" =~ ^[a-z]([a-z0-9-]{0,61}[a-z0-9])?$ ]] ||
  die "--cloud-armor-policy-name is not a valid resource name."
[[ "${BIGQUERY_DATASET}" =~ ^[A-Za-z_][A-Za-z0-9_]{0,1023}$ ]] ||
  die "--bigquery-dataset is not a valid BigQuery dataset ID."
if [[ -n "${TLS_CERTIFICATE_NAME}" ]] &&
  [[ ! "${TLS_CERTIFICATE_NAME}" =~ ^[a-z]([a-z0-9-]{0,61}[a-z0-9])?$ ]]; then
  die "--tls-certificate-name is not a valid resource name."
fi

IFS=. read -r -a ipv4_octets <<<"${GLOBAL_IPV4_ADDRESS}"
[[ ${#ipv4_octets[@]} -eq 4 ]] || die "--global-ipv4-address is not IPv4."
for octet in "${ipv4_octets[@]}"; do
  if [[ ! "${octet}" =~ ^[0-9]{1,3}$ ]] || ((10#${octet} > 255)); then
    die "--global-ipv4-address is not IPv4."
  fi
done

[[ -d "${REPO_ROOT}/k8s" ]] || die "The Kubernetes source directory is missing."
mkdir -p "${REPO_ROOT}/.generated"
temporary_dir="$(mktemp -d "${REPO_ROOT}/.generated/render.XXXXXX")"
cleanup() {
  if [[ -n "${temporary_dir}" ]]; then
    rm -rf -- "${temporary_dir}"
  fi
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

cp -R "${REPO_ROOT}/k8s/." "${temporary_dir}/"

# A disabled HTTPS baseline still receives a syntactically valid inert value;
# deploy.sh never applies a TLS overlay unless HTTPS is explicitly enabled.
if [[ -z "${TLS_CERTIFICATE_NAME}" ]]; then
  TLS_CERTIFICATE_NAME="https-not-configured"
fi

find "${temporary_dir}" -type f -exec sed -i \
  -e "s|\${GCP_PROJECT_ID}|${GCP_PROJECT_ID}|g" \
  -e "s|\${GCP_PROJECT_NUMBER}|${GCP_PROJECT_NUMBER}|g" \
  -e "s|\${ASSESSMENT_DEPLOYER_EMAIL}|${ASSESSMENT_DEPLOYER_EMAIL}|g" \
  -e "s|\${ASSESSMENT_CLUSTER_ADMIN_EMAIL}|${ASSESSMENT_CLUSTER_ADMIN_EMAIL}|g" \
  -e "s|\${APP_A_GSA_EMAIL}|${APP_A_GSA_EMAIL}|g" \
  -e "s|\${GRAFANA_GSA_EMAIL}|${GRAFANA_GSA_EMAIL}|g" \
  -e "s|\${BIGQUERY_DATASET}|${BIGQUERY_DATASET}|g" \
  -e "s|GLOBAL_IP_ADDRESS|${GLOBAL_IPV4_ADDRESS}|g" \
  -e "s|CLOUD_ARMOR_POLICY|${CLOUD_ARMOR_POLICY_NAME}|g" \
  -e "s|TLS_CERTIFICATE_NAME|${TLS_CERTIFICATE_NAME}|g" {} +

if grep -RIn "\\\${[^}]*}" "${temporary_dir}" >&2; then
  die "Rendered manifests contain an unapproved or unresolved \${...} token."
fi
if grep -RInE 'GLOBAL_IP_ADDRESS|CLOUD_ARMOR_POLICY|TLS_CERTIFICATE_NAME' "${temporary_dir}" >&2; then
  die "Rendered manifests contain an unresolved approved token."
fi

rm -rf -- "${OUTPUT_DIR}"
mv "${temporary_dir}" "${OUTPUT_DIR}"
temporary_dir=""
printf 'Rendered manifests are available in %s\n' "${OUTPUT_DIR}"
