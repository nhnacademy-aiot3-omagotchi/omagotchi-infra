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

extract_named_step() {
  local step_name="$1"
  local file="$2"

  awk -v target="      - name: ${step_name}" '
    $0 == target {
      capture = 1
    }
    capture && $0 != target && /^      - name:/ {
      exit
    }
    capture {
      print
    }
  ' "${file}"
}

assert_same_named_step() {
  local step_name="$1"
  local first_file="$2"
  local second_file="$3"
  local message="$4"

  assert_contains "      - name: ${step_name}" "${first_file}" "${message}"
  assert_contains "      - name: ${step_name}" "${second_file}" "${message}"

  if ! diff -u -B \
    <(extract_named_step "${step_name}" "${first_file}") \
    <(extract_named_step "${step_name}" "${second_file}") \
    >/dev/null; then
    fail "${message}"
  fi
}

deploy_condition="if: \${{ github.ref == 'refs/heads/main' && vars.DEPLOY_ENABLED == 'true' }}"

assert_not_contains '  workflow_call:' "${SYNC_WORKFLOW}" \
  "Environment Secret을 사용할 수 없는 Runtime 설정 재사용 진입점이 남아 있습니다."
assert_contains '  workflow_dispatch:' "${SYNC_WORKFLOW}" \
  "Runtime 설정만 동기화하는 수동 진입점이 없습니다."
assert_contains '    environment:' "${SYNC_WORKFLOW}" \
  "수동 동기화 Job이 production Environment를 사용하지 않습니다."
assert_contains '      name: production' "${SYNC_WORKFLOW}" \
  "수동 동기화 Job의 Environment가 production이 아닙니다."
assert_contains "DEPLOY_SSH_KEY: \${{ secrets.DEPLOY_SSH_KEY }}" "${SYNC_WORKFLOW}" \
  "수동 동기화 Workflow가 production의 DEPLOY_SSH_KEY를 공급받지 않습니다."
assert_contains "DEPLOY_KNOWN_HOSTS: \${{ secrets.DEPLOY_KNOWN_HOSTS }}" "${SYNC_WORKFLOW}" \
  "수동 동기화 Workflow가 production의 DEPLOY_KNOWN_HOSTS를 공급받지 않습니다."
assert_contains "PROD_ENV: \${{ secrets.PROD_ENV }}" "${SYNC_WORKFLOW}" \
  "수동 동기화 Workflow가 production의 PROD_ENV를 공급받지 않습니다."

assert_not_contains '      - .github/workflows/sync-runtime-config.yml' "${DEPLOY_WORKFLOW}" \
  "수동 Runtime 설정 Workflow 변경만으로 전체 Infra 자동 배포가 실행됩니다."
assert_not_contains '      - tests/**' "${DEPLOY_WORKFLOW}" \
  "Test 변경만으로 전체 Infra 자동 배포가 실행됩니다."
assert_not_contains '      - .github/workflows/ci.yml' "${DEPLOY_WORKFLOW}" \
  "PR 검증 Workflow 변경만으로 전체 Infra 자동 배포가 실행됩니다."
assert_contains "  group: infra-deploy-\${{ github.ref }}" "${DEPLOY_WORKFLOW}" \
  "연속 main 반영의 Infra 자동 배포 Workflow가 직렬화되지 않습니다."
assert_contains '  cancel-in-progress: false' "${DEPLOY_WORKFLOW}" \
  "실행 중인 Infra 자동 배포가 후속 main 반영으로 취소될 수 있습니다."
assert_contains '    timeout-minutes: 80' "${DEPLOY_WORKFLOW}" \
  "Runtime 설정 동기화와 전체 Infra 배포를 합친 대기 예산이 보존되지 않습니다."
assert_contains '    environment:' "${DEPLOY_WORKFLOW}" \
  "Infra 자동 배포 Job이 production Environment를 사용하지 않습니다."
assert_contains '      name: production' "${DEPLOY_WORKFLOW}" \
  "Infra 자동 배포 Job의 Environment가 production이 아닙니다."
assert_not_contains '  sync-runtime-config:' "${DEPLOY_WORKFLOW}" \
  "Environment Secret을 전달하지 못하는 재사용 Workflow Job이 남아 있습니다."
assert_not_contains 'uses: ./.github/workflows/sync-runtime-config.yml' "${DEPLOY_WORKFLOW}" \
  "Infra 배포가 Environment Secret을 재사용 Workflow 경계 너머로 전달합니다."
assert_contains '      - validate' "${DEPLOY_WORKFLOW}" \
  "Infra 전체 배포가 사전 검증 성공을 기다리지 않습니다."
assert_contains '      - name: Sync runtime configuration' "${DEPLOY_WORKFLOW}" \
  "Infra 배포 Job에 Runtime 설정 동기화 단계가 없습니다."
assert_contains "DEPLOY_SSH_KEY: \${{ secrets.DEPLOY_SSH_KEY }}" "${DEPLOY_WORKFLOW}" \
  "Infra 배포 Job이 production의 DEPLOY_SSH_KEY를 직접 공급받지 않습니다."
assert_contains "DEPLOY_KNOWN_HOSTS: \${{ secrets.DEPLOY_KNOWN_HOSTS }}" "${DEPLOY_WORKFLOW}" \
  "Infra 배포 Job이 production의 DEPLOY_KNOWN_HOSTS를 직접 공급받지 않습니다."
assert_contains "PROD_ENV: \${{ secrets.PROD_ENV }}" "${DEPLOY_WORKFLOW}" \
  "Infra 배포 Job이 production의 PROD_ENV를 직접 공급받지 않습니다."
assert_contains '            < scripts/sync-runtime-config.sh' "${DEPLOY_WORKFLOW}" \
  "Infra 배포 Job이 검증된 Runtime 설정 동기화 Script를 실행하지 않습니다."
assert_before '      - name: Configure SSH' '      - name: Sync runtime configuration' \
  "${DEPLOY_WORKFLOW}" "SSH 설정 이전에 Runtime 설정 동기화가 실행될 수 있습니다."
assert_before '      - name: Sync runtime configuration' '      - name: Deploy infrastructure' \
  "${DEPLOY_WORKFLOW}" "Runtime 설정 동기화가 Infra 전체 배포보다 먼저 실행되지 않습니다."
assert_same_named_step 'Configure SSH' "${DEPLOY_WORKFLOW}" "${SYNC_WORKFLOW}" \
  "자동 배포의 SSH 설정이 검증된 수동 Runtime 동기화 Workflow와 다릅니다."
assert_same_named_step 'Sync runtime configuration' "${DEPLOY_WORKFLOW}" "${SYNC_WORKFLOW}" \
  "자동 배포의 Runtime 동기화가 검증된 수동 Workflow와 다릅니다."
assert_not_contains "github.event_name == 'workflow_dispatch'" "${DEPLOY_WORKFLOW}" \
  "Infra 전체 배포가 수동 실행으로만 제한되어 있습니다."

if [[ "$(grep -Fc -- "${deploy_condition}" "${DEPLOY_WORKFLOW}")" != "1" ]]; then
  fail "Infra 배포에 main·Kill Switch 조건이 정확히 한 번 적용되지 않았습니다."
fi

echo "Workflow contract tests passed"
