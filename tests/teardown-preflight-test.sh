#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
SCRIPT="${REPO_ROOT}/scripts/teardown.sh"
FAKE_BIN="${REPO_ROOT}/tests/fixtures/teardown"
HARNESS_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/teardown-preflight-regression.XXXXXX")"
trap 'rm -rf -- "${HARNESS_ROOT}"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  return 1
}

invoke() {
  local name="$1"
  shift

  CASE_ROOT="${HARNESS_ROOT}/${name}"
  OUTPUT_FILE="${CASE_ROOT}/stdout"
  ERROR_FILE="${CASE_ROOT}/stderr"
  LIFECYCLE_LOG="${CASE_ROOT}/lifecycle.log"
  mkdir -p "${CASE_ROOT}"

  set +e
  env \
    -u GCP_CLUSTER_ADMIN_EMAIL \
    -u TF_VAR_cluster_admin_email \
    "$@" \
    PATH="${FAKE_BIN}:${REPO_ROOT}/.tools/bin:/usr/bin:/bin" \
    LIFECYCLE_LOG="${LIFECYCLE_LOG}" \
    GITHUB_ACTIONS=true \
    GITHUB_REF=refs/heads/main \
    GCP_PROJECT_ID=example-project \
    TF_STATE_BUCKET=example-project-tfstate \
    GCP_WIF_PROVIDER=example-provider \
    GCP_DEPLOYER_SERVICE_ACCOUNT=deployer@example-project.iam.gserviceaccount.com \
    "${SCRIPT}" --project-id example-project --confirmation 'DESTROY example-project' \
    >"${OUTPUT_FILE}" 2>"${ERROR_FILE}"
  STATUS=$?
  set -e
}

assert_preflight_rejection() {
  local expected_error="$1"

  [[ "${STATUS}" -eq 1 ]] || fail "expected status 1, got ${STATUS}"
  grep -F "${expected_error}" "${ERROR_FILE}" >/dev/null ||
    fail "expected '${expected_error}'"
  [[ ! -e "${LIFECYCLE_LOG}" ]] ||
    fail 'invalid operator input reached a mutation-capable command'
}

test_missing_operator_stops_before_mutation() {
  invoke missing
  assert_preflight_rejection 'GCP_CLUSTER_ADMIN_EMAIL is required.'
}

test_malformed_operator_stops_before_mutation() {
  invoke malformed GCP_CLUSTER_ADMIN_EMAIL=not-an-email
  assert_preflight_rejection 'Invalid GCP_CLUSTER_ADMIN_EMAIL.'
}

test_mismatched_terraform_operator_stops_before_mutation() {
  invoke mismatch \
    GCP_CLUSTER_ADMIN_EMAIL=operator@example.com \
    TF_VAR_cluster_admin_email=different@example.com
  assert_preflight_rejection 'TF_VAR_cluster_admin_email must match GCP_CLUSTER_ADMIN_EMAIL.'
}

test_valid_operator_exports_normalized_terraform_input() {
  invoke normalized \
    GCP_CLUSTER_ADMIN_EMAIL=Operator@Example.com \
    TF_VAR_cluster_admin_email=OPERATOR@EXAMPLE.COM

  [[ "${STATUS}" -eq 97 ]] || fail "expected fake mktemp status 97, got ${STATUS}"
  grep -Fx 'mktemp' "${LIFECYCLE_LOG}" >/dev/null ||
    fail 'valid preflight did not reach the controlled boundary'
  grep -Fx 'TF_VAR_CLUSTER_ADMIN_EMAIL=operator@example.com' "${LIFECYCLE_LOG}" >/dev/null ||
    fail 'Terraform operator input was not normalized before the controlled boundary'
}

run_test() {
  local test_name="$1"
  local status

  set +e
  (set -e; "${test_name}")
  status=$?
  set -e
  if [[ "${status}" -eq 0 ]]; then
    printf 'PASS: %s\n' "${test_name}"
  else
    printf 'FAIL: %s\n' "${test_name}" >&2
    failures=$((failures + 1))
  fi
}

failures=0
for test_name in \
  test_missing_operator_stops_before_mutation \
  test_malformed_operator_stops_before_mutation \
  test_mismatched_terraform_operator_stops_before_mutation \
  test_valid_operator_exports_normalized_terraform_input; do
  run_test "${test_name}"
done

[[ "${failures}" -eq 0 ]] || fail "${failures} teardown preflight test(s) failed"
