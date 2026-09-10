#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
TEST_TMP_DIR="$(mktemp -d)"
trap 'rm -rf -- "${TEST_TMP_DIR}"' EXIT

fail() { echo "$1" >&2; exit 1; }

# 실제 Smoke 스크립트 실행, 외부 HTTP와 대기만 대역 사용.
# shellcheck disable=SC2329 # 자식 Bash에서 사용하는 HTTP 대역
curl() {
  local url="${*: -1}"
  printf '%s\n' "${url}" >>"${SMOKE_TEST_CALLS}"
  case "${SMOKE_TEST_SCENARIO}" in
    connection-failure) return 7 ;;
    retry)
      if [[ "$(wc -l <"${SMOKE_TEST_CALLS}")" -eq 1 ]]; then return 22; fi
      ;;
    wrong-body)
      printf 'Unrelated login page\n'
      return 0
      ;;
  esac
  case "${url}" in
    https://example.invalid/) printf 'Omagotchi\n' ;;
    */health)
      if [[ "${url}" == */api/health ]]; then printf '{"status":"UP"}\n'; else printf 'ok\n'; fi
      ;;
    */api/v1/rules/ping) printf '{"service":"rule-service","status":"UP"}\n' ;;
    */api/v1/internal/engines/self) printf '404' ;;
    */api/v1/users/me|*/api/v1/cohorts|*/api/v1/rules)
      if [[ "${SMOKE_TEST_SCENARIO}" == exposed-api ]]; then printf '200'; else printf '401'; fi
      ;;
    *) return 2 ;;
  esac
}
# shellcheck disable=SC2329 # 자식 Bash의 대기 제거
sleep() { :; }
export -f curl sleep

for scenario in success retry connection-failure wrong-body exposed-api; do
  calls="${TEST_TMP_DIR}/${scenario}.calls"
  output="${TEST_TMP_DIR}/${scenario}.output"
  : >"${calls}"
  result=0
  SMOKE_TEST_SCENARIO="${scenario}" SMOKE_TEST_CALLS="${calls}" \
    SMOKE_ATTEMPTS=3 SMOKE_INTERVAL_SECONDS=0 \
    bash "${INFRA_DIR}/scripts/smoke-test.sh" https://example.invalid >"${output}" 2>&1 || result=$?
  case "${scenario}" in
    success|retry)
      [[ "${result}" == 0 ]] || { cat "${output}" >&2; fail "정상 응답의 Smoke 검사 실패: ${scenario}"; }
      grep -Fq 'Smoke Test 완료' "${output}" || fail "Smoke 완료 확인 누락"
      expected=1
      [[ "${scenario}" != retry ]] || expected=2
      [[ "$(grep -Fxc 'https://example.invalid/' "${calls}")" == "${expected}" ]] || fail "일시 실패의 재시도 횟수 오류"
      ;;
    connection-failure|wrong-body)
      [[ "${result}" != 0 ]] || fail "연결 실패·잘못된 본문을 성공 처리"
      [[ "$(wc -l <"${calls}")" -eq 3 ]] || fail "재시도 상한 위반"
      if grep -Fq 'example.invalid/health' "${calls}"; then fail "실패 이후 후속 경로 검사 실행"; fi
      ;;
    exposed-api)
      [[ "${result}" != 0 ]] || fail "인증 없는 보호 API 접근을 정상 처리"
      [[ "$(grep -Fc '/api/v1/users/me' "${calls}")" == 3 ]] || fail "보호 API 상태 검사 재시도 상한 위반"
      if grep -Fq '/api/v1/cohorts' "${calls}"; then fail "보안 경계 검사 실패 이후 진행"; fi
      ;;
  esac
done

# 주소를 생략하거나 잘못 입력한 경우 HTTP 호출 전 중단.
calls="${TEST_TMP_DIR}/invalid-address.calls"
for url in '' 'not-a-url'; do
  : >"${calls}"
  if SMOKE_TEST_SCENARIO=success SMOKE_TEST_CALLS="${calls}" \
    bash "${INFRA_DIR}/scripts/smoke-test.sh" "${url}" >/dev/null 2>&1; then
    fail "잘못된 Smoke 주소 허용"
  fi
  [[ ! -s "${calls}" ]] || fail "잘못된 Smoke 주소로 HTTP 호출 실행"
done
: >"${calls}"
if SMOKE_TEST_SCENARIO=success SMOKE_TEST_CALLS="${calls}" \
  bash "${INFRA_DIR}/scripts/smoke-test.sh" >/dev/null 2>&1; then
  fail "Smoke 주소 생략 허용"
fi
[[ ! -s "${calls}" ]] || fail "Smoke 주소 생략 시 HTTP 호출 실행"

echo "Smoke response, retry and failure tests passed"
