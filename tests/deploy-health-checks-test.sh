#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

fail() {
  echo "$1" >&2
  exit 1
}

for invalid_config in \
  "RULE_ENGINE_WAIT_ATTEMPTS=0" \
  "RULE_ENGINE_WAIT_ATTEMPTS=invalid" \
  "RULE_ENGINE_WAIT_INTERVAL_SECONDS=-1" \
  "RULE_ENGINE_STABLE_CHECKS=0" \
  "RULE_ENGINE_STABLE_CHECKS=37"; do
  # shellcheck disable=SC2016 # $1은 자식 Bash의 positional parameter
  if env ${invalid_config} bash -c 'source "$1"' _ "${INFRA_DIR}/scripts/rule-engine.sh" \
    >/dev/null 2>&1; then
    fail "잘못된 Rule Engine 대기 설정이 허용되었습니다: ${invalid_config}"
  fi
done

# 동적 절대 경로 사용. 실제 파일은 아래 source로 직접 로드.
# shellcheck disable=SC1091
source "${INFRA_DIR}/scripts/rule-engine.sh"

fail_stage=""
calls=()

wait_rule_engine_registered() {
  local _env_file="$1"
  local engine_id="$2"

  calls+=("registered:${engine_id}")
  [[ "${fail_stage}" != "${engine_id}" ]]
}

wait_rule_engine_pair() {
  local _env_file="$1"

  calls+=("pair")
  [[ "${fail_stage}" != "pair" ]]
}

for fail_stage in engine-a engine-b pair; do
  calls=()

  # 실제 함수는 위의 source에서 로드되며, 아래 재정의는 다음 테스트의 Test Double.
  # shellcheck disable=SC2218
  if wait_rule_engine_cluster fixture.env >/dev/null 2>&1; then
    fail "Rule Engine 하위 검사 실패가 전체 실패로 전파되지 않았습니다: ${fail_stage}"
  fi

  case "${fail_stage}" in
  engine-a) expected="registered:engine-a" ;;
  engine-b) expected="registered:engine-a registered:engine-b" ;;
  pair) expected="registered:engine-a registered:engine-b pair" ;;
  esac

  [[ "${calls[*]}" == "${expected}" ]] ||
    fail "Rule Engine 실패 이후 검사가 계속 실행되었습니다: ${calls[*]}"
done

fail_stage="none"
calls=()
# shellcheck disable=SC2218
wait_rule_engine_cluster fixture.env >/dev/null
[[ "${calls[*]}" == "registered:engine-a registered:engine-b pair" ]] ||
  fail "Rule Engine 정상 검사 순서가 올바르지 않습니다: ${calls[*]}"

# deploy-service.sh의 main guard를 통해 배포를 실행하지 않고 실제 함수를 로드.
# shellcheck disable=SC1091
source "${INFRA_DIR}/scripts/deploy-service.sh"

wait_eureka_application() {
  local _env_file="$1"
  local application_name="$2"

  calls+=("eureka:${application_name}")
  [[ "${fail_stage}" != "${application_name}" ]]
}

wait_rule_engine_cluster() {
  local _env_file="$1"

  calls+=("rule-cluster")
  [[ "${fail_stage}" != "rule-cluster" ]]
}

for fail_stage in \
  FRONTEND \
  GATEWAY-SERVICE \
  IDENTITY-SERVICE \
  LEARNING-SERVICE \
  rule-cluster; do
  calls=()

  if wait_discovery_clients fixture.env >/dev/null 2>&1; then
    fail "Discovery 하위 검사 실패가 전체 실패로 전파되지 않았습니다: ${fail_stage}"
  fi

  case "${fail_stage}" in
  FRONTEND)
    expected="eureka:FRONTEND"
    ;;
  GATEWAY-SERVICE)
    expected="eureka:FRONTEND eureka:GATEWAY-SERVICE"
    ;;
  IDENTITY-SERVICE)
    expected="eureka:FRONTEND eureka:GATEWAY-SERVICE eureka:IDENTITY-SERVICE"
    ;;
  LEARNING-SERVICE)
    expected="eureka:FRONTEND eureka:GATEWAY-SERVICE eureka:IDENTITY-SERVICE eureka:LEARNING-SERVICE"
    ;;
  rule-cluster)
    expected="eureka:FRONTEND eureka:GATEWAY-SERVICE eureka:IDENTITY-SERVICE eureka:LEARNING-SERVICE rule-cluster"
    ;;
  esac

  [[ "${calls[*]}" == "${expected}" ]] ||
    fail "Discovery 실패 이후 검사가 계속 실행되었습니다: ${calls[*]}"
done

fail_stage="none"
calls=()
wait_discovery_clients fixture.env >/dev/null
[[ "${calls[*]}" == "eureka:FRONTEND eureka:GATEWAY-SERVICE eureka:IDENTITY-SERVICE eureka:LEARNING-SERVICE rule-cluster" ]] ||
  fail "Discovery 정상 검사 순서가 올바르지 않습니다: ${calls[*]}"

echo "Deploy health check failure propagation tests passed"
