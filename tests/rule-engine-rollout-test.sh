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

assert_equals() {
  local expected="$1"
  local actual="$2"
  local message="$3"

  [[ "${actual}" == "${expected}" ]] ||
    fail "${message}: expected='${expected}', actual='${actual}'"
}

# shellcheck disable=SC1091
source "${INFRA_DIR}/scripts/rule-engine.sh"
# shellcheck disable=SC1091
source "${INFRA_DIR}/scripts/deploy-service.sh"

assert_equals "${RULE_ENGINE_B}" "$(rule_engine_other_service "${RULE_ENGINE_A}")" \
  "engine-a의 반대편 서비스 선택 실패"
assert_equals "${RULE_ENGINE_A}" "$(rule_engine_other_service "${RULE_ENGINE_B}")" \
  "engine-b의 반대편 서비스 선택 실패"

if rule_engine_other_service unknown >/dev/null 2>&1; then
  fail "알 수 없는 Rule Engine 서비스가 허용되었습니다."
fi

# command substitution 안에서 호출되는 Test Double의 진행 상태를 파일로 공유.
pair_index_file="${TEST_TMP_DIR}/pair-index"
pair_sequence=()

set_pair_sequence() {
  pair_sequence=("$@")
  printf '0\n' >"${pair_index_file}"
}

rule_engine_resolve_pair() {
  local _env_file="$1"
  local index

  index="$(<"${pair_index_file}")"
  ((index < ${#pair_sequence[@]})) || return 1
  printf '%s\n' "${pair_sequence[index]}"
  printf '%s\n' "$((index + 1))" >"${pair_index_file}"
}

RULE_ENGINE_WAIT_ATTEMPTS=3
RULE_ENGINE_WAIT_INTERVAL_SECONDS=0
RULE_ENGINE_STABLE_CHECKS=3

set_pair_sequence \
  "${RULE_ENGINE_A} ${RULE_ENGINE_B}" \
  "${RULE_ENGINE_B} ${RULE_ENGINE_A}" \
  "${RULE_ENGINE_A} ${RULE_ENGINE_B}"

if wait_rule_engine_pair fixture.env >/dev/null 2>&1; then
  fail "역할 조합이 변경됐는데 안정 상태로 판정했습니다."
fi

set_pair_sequence \
  "${RULE_ENGINE_A} ${RULE_ENGINE_B}" \
  "${RULE_ENGINE_A} ${RULE_ENGINE_B}" \
  "${RULE_ENGINE_A} ${RULE_ENGINE_B}"

wait_rule_engine_pair fixture.env >/dev/null
assert_equals "${RULE_ENGINE_A} ${RULE_ENGINE_B}" "${RULE_ENGINE_STABLE_PAIR}" \
  "동일 역할 조합의 연속 안정화 결과가 보존되지 않았습니다."

cluster_pair="${RULE_ENGINE_A} ${RULE_ENGINE_B}"
cluster_result=0
cluster_calls=()

wait_rule_engine_cluster() {
  local env_file="$1"

  cluster_calls+=("${env_file}")
  RULE_ENGINE_STABLE_PAIR="${cluster_pair}"
  return "${cluster_result}"
}

rule_engine_prepare_rollout fixture.env 0 0
assert_equals "${RULE_ENGINE_A}" "${RULE_ENGINE_ROLLOUT_FIRST}" "0대 부트스트랩 1차 대상 오류"
assert_equals "${RULE_ENGINE_B}" "${RULE_ENGINE_ROLLOUT_SECOND}" "0대 부트스트랩 2차 대상 오류"

rule_engine_prepare_rollout fixture.env 1 0
assert_equals "${RULE_ENGINE_B}" "${RULE_ENGINE_ROLLOUT_FIRST}" "engine-b 누락 복구 순서 오류"
assert_equals "${RULE_ENGINE_A}" "${RULE_ENGINE_ROLLOUT_SECOND}" "engine-b 누락 후 2차 대상 오류"

rule_engine_prepare_rollout fixture.env 0 1
assert_equals "${RULE_ENGINE_A}" "${RULE_ENGINE_ROLLOUT_FIRST}" "engine-a 누락 복구 순서 오류"
assert_equals "${RULE_ENGINE_B}" "${RULE_ENGINE_ROLLOUT_SECOND}" "engine-a 누락 후 2차 대상 오류"

cluster_pair="${RULE_ENGINE_B} ${RULE_ENGINE_A}"
cluster_calls=()
rule_engine_prepare_rollout fixture.env 1 1
assert_equals "${RULE_ENGINE_A}" "${RULE_ENGINE_ROLLOUT_FIRST}" "현재 STANDBY 1차 선택 오류"
assert_equals "${RULE_ENGINE_B}" "${RULE_ENGINE_ROLLOUT_SECOND}" "반대편 물리 인스턴스 선택 오류"
assert_equals "fixture.env" "${cluster_calls[*]}" "2대 실행 상태의 사전 안정화 누락"

cluster_result=1
if rule_engine_prepare_rollout fixture.env 1 1 >/dev/null 2>&1; then
  fail "불안정한 2대 클러스터의 롤아웃이 허용되었습니다."
fi
assert_equals "" "${RULE_ENGINE_ROLLOUT_FIRST}" "실패한 롤아웃 계획에 1차 대상이 남았습니다."
assert_equals "" "${RULE_ENGINE_ROLLOUT_SECOND}" "실패한 롤아웃 계획에 2차 대상이 남았습니다."
cluster_result=0

running_a=0
running_b=0
ps_failure=""
infra_calls=()
infra_cluster_pair="${RULE_ENGINE_A} ${RULE_ENGINE_B}"
ps_calls_file="${TEST_TMP_DIR}/ps-calls"
unexpected_calls_file="${TEST_TMP_DIR}/unexpected-calls"
: >"${unexpected_calls_file}"

rule_compose() {
  local env_file="$1"
  shift

  if [[ "$1" != "ps" ]]; then
    printf 'unexpected:%s\n' "$*" >>"${unexpected_calls_file}"
    return 2
  fi
  local service="${*: -1}"
  printf '%s\n' "${service}" >>"${ps_calls_file}"

  [[ "${service}" != "${ps_failure}" ]] || return 2

  case "${service}" in
  "${RULE_ENGINE_A}") ((running_a == 1)) && printf 'container-a\n' ;;
  "${RULE_ENGINE_B}") ((running_b == 1)) && printf 'container-b\n' ;;
  *)
    printf 'unknown-service:%s\n' "${service}" >>"${unexpected_calls_file}"
    return 2
    ;;
  esac

  return 0
}

rule_engine_start() {
  local env_file="$1"
  local service="$2"

  infra_calls+=("start:${env_file}:${service}")

  case "${service}" in
  "${RULE_ENGINE_A}") running_a=1 ;;
  "${RULE_ENGINE_B}") running_b=1 ;;
  esac
}

wait_rule_engine_registered() {
  infra_calls+=("registered:$1:$2")
}

wait_rule_engine_cluster() {
  infra_calls+=("cluster:$1")
  RULE_ENGINE_STABLE_PAIR="${infra_cluster_pair}"
}

running_a=0
running_b=0
infra_calls=()
: >"${ps_calls_file}"
rollout_rule_engine_infra fixture.env
assert_equals \
  "start:fixture.env:${RULE_ENGINE_A} registered:fixture.env:engine-a start:fixture.env:${RULE_ENGINE_B} registered:fixture.env:engine-b cluster:fixture.env" \
  "${infra_calls[*]}" \
  "0대 부트스트랩 호출 순서 오류"
assert_equals "${RULE_ENGINE_A} ${RULE_ENGINE_B}" "$(tr '\n' ' ' <"${ps_calls_file}" | sed 's/ $//')" \
  "0대 부트스트랩 실행 상태 조회 오류"

running_a=1
running_b=0
infra_calls=()
: >"${ps_calls_file}"
rollout_rule_engine_infra fixture.env
assert_equals \
  "start:fixture.env:${RULE_ENGINE_B} registered:fixture.env:engine-b cluster:fixture.env start:fixture.env:${RULE_ENGINE_A} registered:fixture.env:engine-a cluster:fixture.env" \
  "${infra_calls[*]}" \
  "engine-b 누락 상태의 복구 순서 오류"

running_a=0
running_b=1
infra_calls=()
: >"${ps_calls_file}"
rollout_rule_engine_infra fixture.env
assert_equals \
  "start:fixture.env:${RULE_ENGINE_A} registered:fixture.env:engine-a cluster:fixture.env start:fixture.env:${RULE_ENGINE_B} registered:fixture.env:engine-b cluster:fixture.env" \
  "${infra_calls[*]}" \
  "engine-a 누락 상태의 복구 순서 오류"

running_a=1
running_b=1
infra_cluster_pair="${RULE_ENGINE_B} ${RULE_ENGINE_A}"
infra_calls=()
: >"${ps_calls_file}"
rollout_rule_engine_infra fixture.env
assert_equals \
  "cluster:fixture.env start:fixture.env:${RULE_ENGINE_A} registered:fixture.env:engine-a cluster:fixture.env start:fixture.env:${RULE_ENGINE_B} registered:fixture.env:engine-b cluster:fixture.env" \
  "${infra_calls[*]}" \
  "2대 실행 상태의 STANDBY 우선 롤아웃 순서 오류"

running_a=1
running_b=1
ps_failure="${RULE_ENGINE_A}"
infra_calls=()
: >"${ps_calls_file}"
if rollout_rule_engine_infra fixture.env >/dev/null 2>&1; then
  fail "Compose 상태 조회 실패 후 롤아웃이 계속됐습니다."
fi
assert_equals "${RULE_ENGINE_A}" "$(<"${ps_calls_file}")" "Compose 상태 조회 실패 위치 오류"
assert_equals "" "${infra_calls[*]-}" "Compose 상태 조회 실패 뒤 후속 호출이 실행되었습니다."
ps_failure=""

calls=()
cluster_call_count=0
initial_pair="${RULE_ENGINE_B} ${RULE_ENGINE_A}"
pair_after_first="${RULE_ENGINE_A} ${RULE_ENGINE_B}"
service_running_a=1
service_running_b=1

wait_rule_engine_cluster() {
  local env_file="$1"

  calls+=("cluster:${env_file}")
  cluster_call_count=$((cluster_call_count + 1))

  if ((cluster_call_count == 1)); then
    RULE_ENGINE_STABLE_PAIR="${initial_pair}"
  else
    RULE_ENGINE_STABLE_PAIR="${pair_after_first}"
  fi
}

compose() {
  local env_file="$1"
  shift
  calls+=("compose:${env_file}:$*")
}

start_service() {
  calls+=("start:$1:$2")
}

wait_rule_engine_registered() {
  calls+=("registered:$1:$2")
}

rule_engine_service_running() {
  calls+=("running:$1:$2")

  case "$2" in
  "${RULE_ENGINE_A}") ((service_running_a == 1)) ;;
  "${RULE_ENGINE_B}") ((service_running_b == 1)) ;;
  *) return 2 ;;
  esac
}

fail_and_rollback() {
  fail "정상 롤아웃에서 rollback이 호출됐습니다: $1"
}

DEPLOY_ENV="deployed.env"
candidate="candidate.env"
rule_stage="none"
rule_first_service=""
rule_second_service=""

deploy_rule_service

assert_equals \
  "running:deployed.env:rule-engine-a running:deployed.env:rule-engine-b cluster:deployed.env compose:candidate.env:pull rule-engine-a rule-engine-b start:candidate.env:rule-engine-a registered:candidate.env:engine-a cluster:candidate.env start:candidate.env:rule-engine-b registered:candidate.env:engine-b cluster:candidate.env" \
  "${calls[*]}" \
  "역할 교체가 발생한 Rule A/B 롤아웃 순서 오류"

assert_equals "${RULE_ENGINE_A}" "${rule_first_service}" "1차 물리 인스턴스 기록 오류"
assert_equals "${RULE_ENGINE_B}" "${rule_second_service}" "2차 물리 인스턴스 기록 오류"

calls=()
cluster_call_count=0
initial_pair="${RULE_ENGINE_A} ${RULE_ENGINE_B}"
pair_after_first="${RULE_ENGINE_A} ${RULE_ENGINE_B}"
rule_stage="none"
rule_first_service=""
rule_second_service=""

deploy_rule_service

assert_equals \
  "running:deployed.env:rule-engine-a running:deployed.env:rule-engine-b cluster:deployed.env compose:candidate.env:pull rule-engine-a rule-engine-b start:candidate.env:rule-engine-b registered:candidate.env:engine-b cluster:candidate.env start:candidate.env:rule-engine-a registered:candidate.env:engine-a cluster:candidate.env" \
  "${calls[*]}" \
  "역할이 유지된 Rule A/B 롤아웃 순서 오류"

calls=()
service_running_a=1
service_running_b=0
rule_stage="none"
rule_first_service=""
rule_second_service=""

if deploy_rule_service >/dev/null 2>&1; then
  fail "Rule Engine 단일 인스턴스 상태에서 서비스별 배포가 허용되었습니다."
fi
assert_equals \
  "running:deployed.env:rule-engine-a running:deployed.env:rule-engine-b" \
  "${calls[*]}" \
  "Rule Engine 실행 상태 사전 검증 오류"
service_running_b=1

restore_calls=()
restore_failure=""

restore_rule_engine() {
  restore_calls+=("restore:$1")
  [[ "$1" != "${restore_failure}" ]]
}

wait_rule_engine_cluster() {
  restore_calls+=("cluster:$1")
}

SMOKE_SCRIPT="true"
base_url="https://example.invalid"
old_tag="0000000000000000000000000000000000000000"
rule_first_service="${RULE_ENGINE_A}"
rule_second_service="${RULE_ENGINE_B}"

rule_stage="first"
rollback_rule_service 2>/dev/null
assert_equals \
  "restore:${RULE_ENGINE_A} cluster:${DEPLOY_ENV}" \
  "${restore_calls[*]}" \
  "1차 실패 복구 대상 오류"

restore_calls=()
rule_stage="second"
rollback_rule_service 2>/dev/null
assert_equals \
  "restore:${RULE_ENGINE_B} restore:${RULE_ENGINE_A} cluster:${DEPLOY_ENV}" \
  "${restore_calls[*]}" \
  "2차 실패의 역순 복구 오류"

restore_calls=()
restore_failure="${RULE_ENGINE_B}"
rule_stage="second"
if rollback_rule_service 2>/dev/null; then
  fail "일부 인스턴스 복구 실패를 성공으로 처리했습니다."
fi
assert_equals \
  "restore:${RULE_ENGINE_B} restore:${RULE_ENGINE_A} cluster:${DEPLOY_ENV}" \
  "${restore_calls[*]}" \
  "2차 인스턴스 복구 실패 후 1차 인스턴스 복구가 누락되었습니다."

[[ ! -s "${unexpected_calls_file}" ]] ||
  fail "예상하지 않은 Compose 호출: $(<"${unexpected_calls_file}")"

echo "Rule Engine rollout tests passed"
