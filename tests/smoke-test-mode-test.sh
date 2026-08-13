#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

fail() {
  echo "$1" >&2
  exit 1
}

assert_equals() {
  local expected="$1"
  local actual="$2"
  local message="$3"

  [[ "${actual}" == "${expected}" ]] ||
    fail "${message}: expected='${expected}', actual='${actual}'"
}

# shellcheck disable=SC1091
source "${INFRA_DIR}/scripts/smoke-test.sh"

calls=()

check() {
  calls+=("check:$1")
}

check_status() {
  calls+=("status:$1:$2")
}

smoke_test_main --skip-rule https://example.invalid >/dev/null
assert_equals \
  "check:/ check:/health check:/api/health status:/api/v1/internal/engines/self:404 status:/api/v1/users/me:401 status:/api/v1/cohorts:401 status:/api/v1/rules:401" \
  "${calls[*]}" \
  "Rule 제외 Smoke Test 범위 오류"

calls=()
smoke_test_main https://example.invalid >/dev/null
assert_equals \
  "check:/ check:/health check:/api/health check:/api/v1/rules/ping status:/api/v1/internal/engines/self:404 status:/api/v1/users/me:401 status:/api/v1/cohorts:401 status:/api/v1/rules:401" \
  "${calls[*]}" \
  "전체 Smoke Test 범위 오류"

echo "Smoke test mode tests passed"
