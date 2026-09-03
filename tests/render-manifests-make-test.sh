#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
HARNESS_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/render-manifests-make-regression.XXXXXX")"
trap 'rm -rf -- "${HARNESS_ROOT}"' EXIT

mkdir -p "${HARNESS_ROOT}/scripts"
cp "${REPO_ROOT}/Makefile" "${HARNESS_ROOT}/Makefile"
cp "${REPO_ROOT}/scripts/render-manifests.sh" "${HARNESS_ROOT}/scripts/render-manifests.sh"
cp -R "${REPO_ROOT}/k8s" "${HARNESS_ROOT}/k8s"

set +e
output="$(
  env -u MAKEFLAGS make --no-print-directory -C "${HARNESS_ROOT}" render-manifests \
    GCP_PROJECT_ID=example-project \
    GCP_PROJECT_NUMBER=123456 \
    GCP_DEPLOYER_SERVICE_ACCOUNT=deployer@example-project.iam.gserviceaccount.com \
    GCP_CLUSTER_ADMIN_EMAIL=operator@example.com \
    APP_A_GSA_EMAIL=app-aa@example-project.iam.gserviceaccount.com \
    GRAFANA_GSA_EMAIL=grafana@example-project.iam.gserviceaccount.com \
    GLOBAL_IPV4_ADDRESS=192.0.2.1 \
    CLOUD_ARMOR_POLICY_NAME=example-policy \
    BIGQUERY_DATASET=example_dataset \
    TLS_CERTIFICATE_NAME= \
    2>&1
)"
status=$?
set -e

if [[ "${status}" -ne 0 ]]; then
  printf '%s\n' "${output}" >&2
  printf 'FAIL: make render-manifests returned %s\n' "${status}" >&2
  exit 1
fi

grep -Fx '    name: operator@example.com' \
  "${HARNESS_ROOT}/.generated/k8s/access/common/operator-cluster-admin.yaml" >/dev/null || {
  printf '%s\n' 'FAIL: Make did not render the operator ClusterRoleBinding subject.' >&2
  exit 1
}
grep -Fx '      - operator@example.com' \
  "${HARNESS_ROOT}/.generated/k8s/access/common/gateway-impersonation.yaml" >/dev/null || {
  printf '%s\n' 'FAIL: Make did not render the operator Gateway impersonation subject.' >&2
  exit 1
}

printf '%s\n' 'PASS: make render-manifests propagates the cluster administrator email'
