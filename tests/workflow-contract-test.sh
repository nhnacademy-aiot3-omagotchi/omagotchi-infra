#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
DEPLOY_WORKFLOW="${INFRA_DIR}/.github/workflows/deploy.yml"
SYNC_WORKFLOW="${INFRA_DIR}/.github/workflows/sync-runtime-config.yml"

fail() { echo "$1" >&2; exit 1; }

assert_contains() {
  local pattern="$1" file="$2" message="$3"
  grep -Fq -- "${pattern}" "${file}" || fail "${message}"
}

assert_before() {
  local first_pattern="$1" second_pattern="$2" file="$3" message="$4"
  local first_line second_line
  first_line="$(grep -Fn -- "${first_pattern}" "${file}" | head -n 1 | cut -d: -f1)"
  second_line="$(grep -Fn -- "${second_pattern}" "${file}" | head -n 1 | cut -d: -f1)"
  [[ -n "${first_line}" && -n "${second_line}" && "${first_line}" -lt "${second_line}" ]] || fail "${message}"
}

# 단계 이름·본문 복사본 비교 대신 공통 진입점 연결 확인.
for workflow in "${INFRA_DIR}/.github/workflows/ci.yml" "${DEPLOY_WORKFLOW}"; do
  assert_contains 'run: bash tests/validate.sh' "${workflow}" "공통 인프라 검증 호출 누락: ${workflow}"
done
for workflow in "${DEPLOY_WORKFLOW}" "${SYNC_WORKFLOW}"; do
  assert_contains 'name: production' "${workflow}" "production Environment 연결 누락: ${workflow}"
  assert_contains 'group: production-deploy' "${workflow}" "배포 동시 실행 방지 누락: ${workflow}"
  assert_contains 'cancel-in-progress: false' "${workflow}" "진행 중인 배포 취소 방지 누락: ${workflow}"
  for secret in DEPLOY_SSH_KEY DEPLOY_KNOWN_HOSTS PROD_ENV; do
    assert_contains "${secret}: \${{ secrets.${secret} }}" "${workflow}" "배포 Secret 전달 누락: ${secret}"
  done
  assert_contains 'run: bash scripts/sync-runtime-remote.sh' "${workflow}" "공통 설정 동기화 호출 누락: ${workflow}"
  assert_before 'run: bash scripts/configure-deploy-ssh.sh' 'run: bash scripts/sync-runtime-remote.sh' \
    "${workflow}" "SSH 준비 이전의 설정 동기화 실행: ${workflow}"
done

# 원격 실행은 새 파일이 없는 서버에서도 시작할 수 있도록 Runner의 본문 전달.
assert_contains '< scripts/sync-runtime-config.sh' "${INFRA_DIR}/scripts/sync-runtime-remote.sh" \
  "서버 설정 동기화 스크립트 전달 누락"
assert_before 'run: bash scripts/sync-runtime-remote.sh' '< scripts/deploy-infra.sh' "${DEPLOY_WORKFLOW}" \
  "설정 동기화 이전의 전체 배포 실행"

# 자동 배포의 대상·실행 조건 확인. 작업 이름·검증 본문·설정값의 복제 제외.
assert_contains "if: \${{ github.ref == 'refs/heads/main' && vars.DEPLOY_ENABLED == 'true' }}" \
  "${DEPLOY_WORKFLOW}" "main·배포 활성화 조건 누락"
assert_contains '      - validate' "${DEPLOY_WORKFLOW}" "검증 성공 전 배포 실행"
assert_contains "group: infra-deploy-\${{ github.ref }}" "${DEPLOY_WORKFLOW}" "연속 main 배포의 직렬화 누락"
assert_contains "if: github.ref == 'refs/heads/main'" "${SYNC_WORKFLOW}" "수동 동기화의 main 조건 누락"
assert_contains 'workflow_dispatch:' "${SYNC_WORKFLOW}" "수동 설정 동기화 진입점 누락"

# 관측 변경의 배포 누락·검증 전용 변경의 불필요한 배포 방지.
push_paths="$(awk '
  /^[^[:space:]#]/ { in_on = ($0 == "on:") }
  /^  [^[:space:]#]/ { in_push = in_on && ($0 == "  push:") }
  /^    [^[:space:]#]/ { in_paths = in_push && ($0 == "    paths:") }
  in_on && in_push && in_paths && /^      - / { print }
' "${DEPLOY_WORKFLOW}")"
grep -Fq 'observability/**' <<<"${push_paths}" || fail "관측 설정 변경의 자동 배포 누락"
if grep -Eq 'tests/|\.github/workflows/(ci|sync-runtime-config)\.yml' <<<"${push_paths}"; then
  fail "검증·수동 동기화 변경만으로 전체 배포 실행"
fi

echo "Workflow entrypoint and deployment guard tests passed"
