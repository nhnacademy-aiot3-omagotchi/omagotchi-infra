#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
DEPLOY_WORKFLOW="${INFRA_DIR}/.github/workflows/deploy.yml"
SYNC_WORKFLOW="${INFRA_DIR}/.github/workflows/sync-runtime-config.yml"

fail() {
  echo "$1" >&2
  exit 1
}

assert_contains() {
  local pattern="$1"
  local file="$2"
  local message="$3"

  grep -Fq -- "${pattern}" "${file}" || fail "${message}"
}

assert_not_contains() {
  local pattern="$1"
  local file="$2"
  local message="$3"

  if grep -Fq -- "${pattern}" "${file}"; then
    fail "${message}"
  fi
}

assert_before() {
  local first_pattern="$1"
  local second_pattern="$2"
  local file="$3"
  local message="$4"
  local first_line
  local second_line

  first_line="$(grep -Fn -- "${first_pattern}" "${file}" | head -n 1 | cut -d: -f1)"
  second_line="$(grep -Fn -- "${second_pattern}" "${file}" | head -n 1 | cut -d: -f1)"
  [[ -n "${first_line}" && -n "${second_line}" && "${first_line}" -lt "${second_line}" ]] ||
    fail "${message}"
}

deploy_condition="if: \${{ github.ref == 'refs/heads/main' && vars.DEPLOY_ENABLED == 'true' }}"

assert_contains '  workflow_call:' "${SYNC_WORKFLOW}" \
  "Runtime 설정 동기화 Workflow의 재사용 진입점이 없습니다."
assert_contains '  workflow_dispatch:' "${SYNC_WORKFLOW}" \
  "Runtime 설정만 동기화하는 수동 진입점이 없습니다."
assert_contains "PROD_ENV: \${{ secrets.PROD_ENV }}" "${SYNC_WORKFLOW}" \
  "재사용 Workflow가 production의 PROD_ENV를 공급받지 않습니다."

assert_contains '      - .github/workflows/sync-runtime-config.yml' "${DEPLOY_WORKFLOW}" \
  "Runtime 설정 동기화 Workflow 변경이 Infra 배포 Trigger에서 누락되었습니다."
assert_not_contains '      - tests/**' "${DEPLOY_WORKFLOW}" \
  "Test 변경만으로 전체 Infra 자동 배포가 실행됩니다."
assert_not_contains '      - .github/workflows/ci.yml' "${DEPLOY_WORKFLOW}" \
  "PR 검증 Workflow 변경만으로 전체 Infra 자동 배포가 실행됩니다."
assert_contains "  group: infra-deploy-\${{ github.ref }}" "${DEPLOY_WORKFLOW}" \
  "연속 main 반영의 Infra 자동 배포 Workflow가 직렬화되지 않습니다."
assert_contains '  cancel-in-progress: false' "${DEPLOY_WORKFLOW}" \
  "실행 중인 Infra 자동 배포가 후속 main 반영으로 취소될 수 있습니다."
assert_contains '  sync-runtime-config:' "${DEPLOY_WORKFLOW}" \
  "Infra 배포에 Runtime 설정 동기화 Job이 없습니다."
assert_contains 'uses: ./.github/workflows/sync-runtime-config.yml' "${DEPLOY_WORKFLOW}" \
  "Infra 배포가 검증된 Runtime 설정 동기화 Workflow를 재사용하지 않습니다."
assert_contains '      - sync-runtime-config' "${DEPLOY_WORKFLOW}" \
  "Infra 전체 배포가 Runtime 설정 동기화 성공을 기다리지 않습니다."
assert_before '  sync-runtime-config:' '  deploy:' "${DEPLOY_WORKFLOW}" \
  "Runtime 설정 동기화 Job이 Infra 전체 배포보다 앞에 선언되지 않았습니다."
assert_not_contains "github.event_name == 'workflow_dispatch'" "${DEPLOY_WORKFLOW}" \
  "Infra 전체 배포가 수동 실행으로만 제한되어 있습니다."

if [[ "$(grep -Fc -- "${deploy_condition}" "${DEPLOY_WORKFLOW}")" != "2" ]]; then
  fail "Runtime 설정 동기화와 Infra 배포에 동일한 main·Kill Switch 조건이 적용되지 않았습니다."
fi

echo "Workflow contract tests passed"
