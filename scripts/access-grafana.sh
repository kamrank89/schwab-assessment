#!/usr/bin/env bash
set -euo pipefail
set +x

umask 077

usage() {
  printf '%s\n' 'Usage: access-grafana.sh --project-id ID --operator-email EMAIL'
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Required command is missing: $1"
}

require_value() {
  [[ -n "${2-}" ]] || die "$1 requires a non-empty value."
}

project_id=""
operator_email=""

while (($# > 0)); do
  case "$1" in
    --project-id)
      require_value "$1" "${2-}"
      project_id="$2"
      shift 2
      ;;
    --operator-email)
      require_value "$1" "${2-}"
      operator_email="$2"
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

[[ "${project_id}" =~ ^[a-z][a-z0-9-]{4,28}[a-z0-9]$ ]] || die "Invalid project ID."
[[ "${operator_email}" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]] ||
  die "--operator-email is not a valid Google user email."
operator_email="${operator_email,,}"

for command_name in gcloud kubectl mktemp install chmod rm; do
  require_command "${command_name}"
done

for variable_name in \
  CLOUDSDK_AUTH_ACCESS_TOKEN \
  CLOUDSDK_AUTH_ACCESS_TOKEN_FILE \
  CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE \
  CLOUDSDK_AUTH_IMPERSONATE_SERVICE_ACCOUNT; do
  [[ -z "${!variable_name+x}" ]] ||
    die "Google Cloud credential override environment variables must be unset."
done

for property_name in \
  auth/access_token_file \
  auth/credential_file_override \
  auth/impersonate_service_account; do
  if ! property_value="$(gcloud config get-value "${property_name}" 2>/dev/null)"; then
    die "Could not verify the active gcloud credential configuration."
  fi
  [[ -z "${property_value}" || "${property_value}" == "(unset)" ]] ||
    die "Google Cloud credential override properties must be unset."
done

active_account="$(gcloud auth list --filter=status:ACTIVE --format='value(account)')"
[[ "${active_account}" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]] ||
  die "The active gcloud account is not a valid user email."
[[ "${active_account,,}" == "${operator_email,,}" ]] ||
  die "The active gcloud account does not match --operator-email."

temporary_parent="${TMPDIR:-/tmp}"
temporary_parent="${temporary_parent%/}"
temporary_root=""
cleanup() {
  if [[ -n "${temporary_root}" &&
        "${temporary_root}" == "${temporary_parent}"/gke-assessment-grafana.* &&
        -d "${temporary_root}" ]]; then
    rm -rf -- "${temporary_root}"
  fi
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

temporary_root="$(mktemp -d "${temporary_parent}/gke-assessment-grafana.XXXXXX")"
chmod 0700 "${temporary_root}"
kubeconfig="${temporary_root}/gateway.kubeconfig"
install -m 0600 /dev/null "${kubeconfig}"

CLOUDSDK_CORE_ACCOUNT="${operator_email}" \
CLOUDSDK_CONTAINER_USE_APPLICATION_DEFAULT_CREDENTIALS=false \
KUBECONFIG="${kubeconfig}" gcloud container fleet memberships get-credentials \
  gke-assessment-us-central1 --location=global --project="${project_id}" \
  --account="${operator_email}" --quiet >/dev/null
chmod 0600 "${kubeconfig}"

authorization_output=""
if ! authorization_output="$(
  CLOUDSDK_CORE_ACCOUNT="${operator_email}" \
  CLOUDSDK_CONTAINER_USE_APPLICATION_DEFAULT_CREDENTIALS=false \
  KUBECONFIG="${kubeconfig}" kubectl auth can-i '*' '*' --all-namespaces
)"; then
  die "The active account is not cluster-admin through Connect Gateway."
fi
[[ "${authorization_output}" == "yes" ]] ||
  die "The active account is not cluster-admin through Connect Gateway."
CLOUDSDK_CORE_ACCOUNT="${operator_email}" \
CLOUDSDK_CONTAINER_USE_APPLICATION_DEFAULT_CREDENTIALS=false \
KUBECONFIG="${kubeconfig}" kubectl -n observability wait \
  --for=condition=Available deployment/grafana --timeout=60s >/dev/null

printf '%s\n' 'Grafana URL: http://127.0.0.1:3000' 'Username: admin'
CLOUDSDK_CORE_ACCOUNT="${operator_email}" \
CLOUDSDK_CONTAINER_USE_APPLICATION_DEFAULT_CREDENTIALS=false \
KUBECONFIG="${kubeconfig}" kubectl -n observability port-forward \
  --address=127.0.0.1 service/grafana 3000:3000
