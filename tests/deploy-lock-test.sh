#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
TEST_TMP_DIR="$(mktemp -d)"
trap 'rm -rf -- "${TEST_TMP_DIR}"' EXIT

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

wait_for_file() {
  local file="$1"
  local process_id="$2"

  for _ in {1..100}; do
    [[ -e "${file}" ]] && return 0
    kill -0 "${process_id}" 2>/dev/null || fail "Lock 보유 Process가 예상보다 먼저 종료되었습니다."
    sleep 0.05
  done

  fail "Lock 획득 완료 신호를 기다리는 중 시간 초과가 발생했습니다."
}

for deploy_script in deploy-service.sh deploy-infra.sh; do
  assert_contains 'DEPLOY_LOCK_WAIT_SECONDS=600' \
    "${INFRA_DIR}/scripts/${deploy_script}" \
    "${deploy_script}의 Lock 대기 시간이 600초로 설정되지 않았습니다."
  assert_contains 'acquire_deploy_lock' \
    "${INFRA_DIR}/scripts/${deploy_script}" \
    "${deploy_script}가 공용 Lock 획득 함수를 사용하지 않습니다."
done

service_lock_function="$(sed -n '/^acquire_deploy_lock() {$/,/^}$/p' \
  "${INFRA_DIR}/scripts/deploy-service.sh")"
infra_lock_function="$(sed -n '/^acquire_deploy_lock() {$/,/^}$/p' \
  "${INFRA_DIR}/scripts/deploy-infra.sh")"
[[ "${service_lock_function}" == "${infra_lock_function}" ]] ||
  fail "서비스 배포와 Infra 배포의 Lock 함수가 서로 다릅니다."

# shellcheck disable=SC1091
source "${INFRA_DIR}/scripts/deploy-service.sh"

fake_success_output="${TEST_TMP_DIR}/fake-success-output"
(
  # shellcheck disable=SC2329 # acquire_deploy_lock 내부 호출용 flock Test Double.
  flock() { return 0; }
  acquire_deploy_lock "${TEST_TMP_DIR}/fake-success.lock" 2 "서비스 배포"
) >"${fake_success_output}" 2>&1
assert_contains "배포 잠금 대기 시작 (서비스 배포): 최대 2초" \
  "${fake_success_output}" "서비스 배포의 Lock 대기 시작 Log가 없습니다."
assert_contains "배포 잠금 획득 (서비스 배포)" \
  "${fake_success_output}" "서비스 배포의 Lock 획득 Log가 없습니다."

fake_timeout_output="${TEST_TMP_DIR}/fake-timeout-output"
if (
  # shellcheck disable=SC2329 # acquire_deploy_lock 내부 호출용 flock Test Double.
  flock() { return 75; }
  acquire_deploy_lock "${TEST_TMP_DIR}/fake-timeout.lock" 2 "Infra 전체 배포"
) >"${fake_timeout_output}" 2>&1; then
  fail "flock 시간 초과가 배포 성공으로 처리되었습니다."
fi
assert_contains "배포 잠금 획득 시간 초과 (Infra 전체 배포): 2초" \
  "${fake_timeout_output}" "Infra 배포의 Lock 시간 초과 Log가 없습니다."

fake_error_output="${TEST_TMP_DIR}/fake-error-output"
if (
  # shellcheck disable=SC2329 # acquire_deploy_lock 내부 호출용 flock Test Double.
  flock() { return 2; }
  acquire_deploy_lock "${TEST_TMP_DIR}/fake-error.lock" 2 "서비스 배포"
) >"${fake_error_output}" 2>&1; then
  fail "flock 실행 오류가 배포 성공으로 처리되었습니다."
fi
assert_contains "배포 잠금 획득 실패 (서비스 배포): flock 종료 코드 2" \
  "${fake_error_output}" "flock 실행 오류 Log가 없습니다."

if ! command -v flock >/dev/null 2>&1; then
  echo "SKIP Deploy lock concurrency tests: flock 명령이 없습니다."
  exit 0
fi

lock_file="${TEST_TMP_DIR}/deploy.lock"
service_ready="${TEST_TMP_DIR}/service-ready"
service_release="${TEST_TMP_DIR}/service-release"
infra_acquired="${TEST_TMP_DIR}/infra-acquired"
service_output="${TEST_TMP_DIR}/service-output"
infra_output="${TEST_TMP_DIR}/infra-output"
mkfifo "${service_release}"

(
  acquire_deploy_lock "${lock_file}" 5 "서비스 배포"
  : >"${service_ready}"
  IFS= read -r _ <"${service_release}"
) >"${service_output}" 2>&1 &
service_pid=$!
wait_for_file "${service_ready}" "${service_pid}"

(
  acquire_deploy_lock "${lock_file}" 5 "Infra 전체 배포"
  : >"${infra_acquired}"
) >"${infra_output}" 2>&1 &
infra_pid=$!

sleep 0.2
[[ ! -e "${infra_acquired}" ]] || fail "서비스 배포 중 Infra 배포가 동시에 Lock을 획득했습니다."
kill -0 "${infra_pid}" 2>/dev/null || fail "Infra 배포가 Lock 해제 전에 실패했습니다."

printf 'release\n' >"${service_release}"
wait "${service_pid}"
wait "${infra_pid}"
[[ -e "${infra_acquired}" ]] || fail "서비스 배포 종료 후 Infra 배포가 Lock을 획득하지 못했습니다."

assert_contains "배포 잠금 대기 시작 (Infra 전체 배포): 최대 5초" \
  "${infra_output}" "Infra 배포의 Lock 대기 시작 Log가 없습니다."
assert_contains "배포 잠금 획득 (Infra 전체 배포)" \
  "${infra_output}" "Infra 배포의 Lock 획득 Log가 없습니다."

infra_ready="${TEST_TMP_DIR}/infra-ready"
infra_release="${TEST_TMP_DIR}/infra-release"
timeout_output="${TEST_TMP_DIR}/timeout-output"
mkfifo "${infra_release}"

(
  acquire_deploy_lock "${lock_file}" 5 "Infra 전체 배포"
  : >"${infra_ready}"
  IFS= read -r _ <"${infra_release}"
) >/dev/null 2>&1 &
infra_holder_pid=$!
wait_for_file "${infra_ready}" "${infra_holder_pid}"

if acquire_deploy_lock "${lock_file}" 1 "서비스 배포" >"${timeout_output}" 2>&1; then
  fail "Infra 배포 중 서비스 배포가 제한 시간 안에 Lock을 획득했습니다."
fi

kill -0 "${infra_holder_pid}" 2>/dev/null || fail "Lock 시간 초과가 실행 중인 Infra 배포를 중단했습니다."
assert_contains "배포 잠금 획득 시간 초과 (서비스 배포): 1초" \
  "${timeout_output}" "서비스 배포의 Lock 시간 초과 Log가 없습니다."

printf 'release\n' >"${infra_release}"
wait "${infra_holder_pid}"

echo "Deploy lock concurrency tests passed"
