#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
SCRIPT="${REPO_ROOT}/scripts/access-grafana.sh"
FAKE_BIN="${REPO_ROOT}/tests/fixtures/access-grafana"
HARNESS_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/access-grafana-regression.XXXXXX")"
trap 'rm -rf -- "${HARNESS_ROOT}"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  return 1
}

new_case() {
  local name="$1"

  CASE_ROOT="${HARNESS_ROOT}/${name}"
  TEST_LOG_DIR="${CASE_ROOT}/logs"
  TEST_TMPDIR="${CASE_ROOT}/tmp"
  OUTPUT_FILE="${CASE_ROOT}/stdout"
  ERROR_FILE="${CASE_ROOT}/stderr"
  mkdir -p "${TEST_LOG_DIR}" "${TEST_TMPDIR}"
  export TEST_LOG_DIR
}

invoke() {
  local override_name="${1-}"

  set +e
  if [[ -n "${override_name}" ]]; then
    env \
      -u CLOUDSDK_AUTH_ACCESS_TOKEN \
      -u CLOUDSDK_AUTH_ACCESS_TOKEN_FILE \
      -u CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE \
      -u CLOUDSDK_AUTH_IMPERSONATE_SERVICE_ACCOUNT \
      -u CLOUDSDK_CORE_ACCOUNT \
      "${override_name}=configured" \
      CLOUDSDK_CONTAINER_USE_APPLICATION_DEFAULT_CREDENTIALS=true \
      PATH="${FAKE_BIN}:/usr/bin:/bin" \
      TMPDIR="${TEST_TMPDIR}" \
      TEST_LOG_DIR="${TEST_LOG_DIR}" \
      ACTIVE_ACCOUNT="Operator@Example.com" \
      GCLOUD_OVERRIDE_PROPERTY="${GCLOUD_OVERRIDE_PROPERTY-}" \
      "${SCRIPT}" --project-id example-project --operator-email operator@example.com \
      >"${OUTPUT_FILE}" 2>"${ERROR_FILE}"
  else
    env \
      -u CLOUDSDK_AUTH_ACCESS_TOKEN \
      -u CLOUDSDK_AUTH_ACCESS_TOKEN_FILE \
      -u CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE \
      -u CLOUDSDK_AUTH_IMPERSONATE_SERVICE_ACCOUNT \
      -u CLOUDSDK_CORE_ACCOUNT \
      CLOUDSDK_CONTAINER_USE_APPLICATION_DEFAULT_CREDENTIALS=true \
      PATH="${FAKE_BIN}:/usr/bin:/bin" \
      TMPDIR="${TEST_TMPDIR}" \
      TEST_LOG_DIR="${TEST_LOG_DIR}" \
      ACTIVE_ACCOUNT="Operator@Example.com" \
      GCLOUD_OVERRIDE_PROPERTY="${GCLOUD_OVERRIDE_PROPERTY-}" \
      "${SCRIPT}" --project-id example-project --operator-email operator@example.com \
      >"${OUTPUT_FILE}" 2>"${ERROR_FILE}"
  fi
  STATUS=$?
  set -e
}

assert_no_override_value_disclosed() {
  if grep -F 'configured' "${OUTPUT_FILE}" "${ERROR_FILE}" >/dev/null; then
    fail 'credential override value was disclosed'
  fi
}

test_auth_override_environment_fails_before_gcloud() {
  local variable

  for variable in \
    CLOUDSDK_AUTH_ACCESS_TOKEN \
    CLOUDSDK_AUTH_ACCESS_TOKEN_FILE \
    CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE \
    CLOUDSDK_AUTH_IMPERSONATE_SERVICE_ACCOUNT; do
    new_case "environment-${variable}"
    GCLOUD_OVERRIDE_PROPERTY='' invoke "${variable}"
    [[ "${STATUS}" -eq 1 ]] || fail "${variable} returned ${STATUS}, expected 1"
    grep -F 'Google Cloud credential override environment variables must be unset.' \
      "${ERROR_FILE}" >/dev/null || fail "${variable} did not report the override rejection"
    [[ ! -e "${TEST_LOG_DIR}/gcloud.log" ]] ||
      fail "${variable} reached gcloud"
    [[ ! -e "${TEST_LOG_DIR}/kubectl.log" ]] ||
      fail "${variable} reached kubectl"
    assert_no_override_value_disclosed
  done
}

test_auth_override_properties_fail_before_credentials() {
  local property

  for property in \
    auth/access_token_file \
    auth/credential_file_override \
    auth/impersonate_service_account; do
    new_case "property-${property//\//-}"
    GCLOUD_OVERRIDE_PROPERTY="${property}" invoke ''
    [[ "${STATUS}" -eq 1 ]] || fail "${property} returned ${STATUS}, expected 1"
    grep -F 'Google Cloud credential override properties must be unset.' \
      "${ERROR_FILE}" >/dev/null || fail "${property} did not report the override rejection"
    [[ -e "${TEST_LOG_DIR}/gcloud.log" ]] || fail "${property} did not inspect gcloud configuration"
    ! grep -F 'COMMAND=container' "${TEST_LOG_DIR}/gcloud.log" >/dev/null ||
      fail "${property} reached Gateway credential generation"
    [[ ! -e "${TEST_LOG_DIR}/kubectl.log" ]] ||
      fail "${property} reached kubectl"
    assert_no_override_value_disclosed
  done
}

test_success_pins_operator_for_gateway_and_auth_plugin() {
  local pin_count

  new_case success
  GCLOUD_OVERRIDE_PROPERTY='' invoke ''
  [[ "${STATUS}" -eq 0 ]] || fail "success path returned ${STATUS}"

  grep -F 'ARG=--account=operator@example.com' "${TEST_LOG_DIR}/gcloud.log" >/dev/null ||
    fail 'Gateway credential generation did not pin --account'
  grep -F 'CORE_ACCOUNT=operator@example.com' "${TEST_LOG_DIR}/gcloud.log" >/dev/null ||
    fail 'Gateway credential generation did not pin CLOUDSDK_CORE_ACCOUNT'
  grep -F 'USE_ADC=false' "${TEST_LOG_DIR}/gcloud.log" >/dev/null ||
    fail 'Gateway credential generation did not force ADC off'

  pin_count="$(grep -c '^CORE_ACCOUNT=operator@example.com$' "${TEST_LOG_DIR}/kubectl.log")"
  [[ "${pin_count}" -eq 3 ]] || fail "expected three account-pinned kubectl calls, got ${pin_count}"
  pin_count="$(grep -c '^USE_ADC=false$' "${TEST_LOG_DIR}/kubectl.log")"
  [[ "${pin_count}" -eq 3 ]] || fail "expected three ADC-disabled kubectl calls, got ${pin_count}"
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
  test_auth_override_environment_fails_before_gcloud \
  test_auth_override_properties_fail_before_credentials \
  test_success_pins_operator_for_gateway_and_auth_plugin; do
  run_test "${test_name}"
done

[[ "${failures}" -eq 0 ]] || fail "${failures} access regression test(s) failed"
