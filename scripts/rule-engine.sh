#!/usr/bin/env bash

# Rule Engine A/B 상태 조회·안정화 판정·배포 순서 계산 Library.
# 직접 실행이 아닌 deploy-infra.sh·deploy-service.sh의 source 대상.
# Infra 전체 배포의 실제 Container 변경 책임: 호출 Script의 rule_engine_start 함수.
# 실제 Compose 실행 책임: 호출 Script가 제공하는 rule_compose 함수.

RULE_ENGINE_A="rule-engine-a"
RULE_ENGINE_B="rule-engine-b"
# 최대 대기 시간: 기본 36회 × 5초.
# 안정 상태: 동일 ACTIVE/STANDBY 조합의 기본 3회 연속 관찰.
RULE_ENGINE_WAIT_ATTEMPTS="${RULE_ENGINE_WAIT_ATTEMPTS:-36}"
RULE_ENGINE_WAIT_INTERVAL_SECONDS="${RULE_ENGINE_WAIT_INTERVAL_SECONDS:-5}"
RULE_ENGINE_STABLE_CHECKS="${RULE_ENGINE_STABLE_CHECKS:-3}"
# 함수 결과 공유용 전역 상태.
# 상태 확인 함수의 진행 로그와 계산 결과를 함께 보존하기 위한 stdout 반환 미사용.
RULE_ENGINE_STABLE_PAIR=""       # "ACTIVE 서비스 STANDBY 서비스"
RULE_ENGINE_ROLLOUT_FIRST=""     # 먼저 교체할 물리 Compose 서비스
RULE_ENGINE_ROLLOUT_SECOND=""    # 나중에 교체할 물리 Compose 서비스

rule_engine_other_service() {
  local service="$1"

  case "${service}" in
    "${RULE_ENGINE_A}") printf '%s\n' "${RULE_ENGINE_B}" ;;
    "${RULE_ENGINE_B}") printf '%s\n' "${RULE_ENGINE_A}" ;;
    *)
      echo "알 수 없는 Rule Engine 서비스: ${service}" >&2
      return 1
      ;;
  esac
}

rule_engine_role() {
  local env_file="$1"
  local service="$2"
  local response

  # Eureka Metadata가 아닌 각 Container의 자기 역할 API 직접 조회.
  # 동일 내부 Secret을 사용하는 운영 Container 내부 통신.
  response="$(
    # shellcheck disable=SC2016 # 변수는 Host가 아니라 Container Shell에서 확장
    rule_compose "${env_file}" exec -T "${service}" sh -ec '
      : "${INTERNAL_SHARED_SECRET:?INTERNAL_SHARED_SECRET is required}"
      curl -fsS \
        --connect-timeout 2 \
        --max-time 5 \
        -H "X-Internal-Token: ${INTERNAL_SHARED_SECRET}" \
        http://127.0.0.1:8080/api/v1/internal/engines/self
    ' 2>/dev/null
  )" || return 1

  sed -nE 's/.*"engineRole"[[:space:]]*:[[:space:]]*"(ACTIVE|STANDBY)".*/\1/p' <<<"${response}"
}

rule_engine_registered() {
  local env_file="$1"
  local engine_id="$2"
  local response

  # Eureka의 RULE-SERVICE 등록 목록에서 고유 engine-id 존재 여부 확인.
  response="$(
    rule_compose "${env_file}" exec -T discovery-service \
      curl -fsS \
      --connect-timeout 2 \
      --max-time 5 \
      -H 'Accept: application/json' \
      http://127.0.0.1:8761/eureka/apps/RULE-SERVICE \
      2>/dev/null
  )" || return 1

  grep -Eq "\"engine-id\"[[:space:]]*:[[:space:]]*\"${engine_id}\"" <<<"${response}"
}

eureka_application_registered() {
  local env_file="$1"
  local application_name="$2"

  # 일반 Eureka Client의 Application 등록 응답 존재 여부 확인.
  rule_compose "${env_file}" exec -T discovery-service \
    curl -fsS \
    --connect-timeout 2 \
    --max-time 5 \
    -H 'Accept: application/json' \
    "http://127.0.0.1:8761/eureka/apps/${application_name}" \
    >/dev/null 2>&1
}

wait_eureka_application() {
  local env_file="$1"
  local application_name="$2"
  local attempt

  for ((attempt = 1; attempt <= RULE_ENGINE_WAIT_ATTEMPTS; attempt++)); do
    if eureka_application_registered "${env_file}" "${application_name}"; then
      echo "Eureka 등록 확인: ${application_name}"
      return 0
    fi

    if (( attempt < RULE_ENGINE_WAIT_ATTEMPTS )); then
      sleep "${RULE_ENGINE_WAIT_INTERVAL_SECONDS}"
    fi
  done

  echo "Eureka 등록 확인 실패: ${application_name}" >&2
  return 1
}

wait_rule_engine_registered() {
  local env_file="$1"
  local engine_id="$2"
  local attempt

  for ((attempt = 1; attempt <= RULE_ENGINE_WAIT_ATTEMPTS; attempt++)); do
    if rule_engine_registered "${env_file}" "${engine_id}"; then
      echo "Eureka Rule Engine 등록 확인: ${engine_id}"
      return 0
    fi

    if (( attempt < RULE_ENGINE_WAIT_ATTEMPTS )); then
      sleep "${RULE_ENGINE_WAIT_INTERVAL_SECONDS}"
    fi
  done

  echo "Eureka Rule Engine 등록 확인 실패: ${engine_id}" >&2
  return 1
}

rule_engine_resolve_pair() {
  local env_file="$1"
  local role_a
  local role_b

  # 허용 상태: ACTIVE 1개와 STANDBY 1개.
  # 거부 상태: 이중 ACTIVE, 이중 STANDBY, UNKNOWN, 응답 실패.
  role_a="$(rule_engine_role "${env_file}" "${RULE_ENGINE_A}" || true)"
  role_b="$(rule_engine_role "${env_file}" "${RULE_ENGINE_B}" || true)"

  if [[ "${role_a}" == "ACTIVE" && "${role_b}" == "STANDBY" ]]; then
    printf '%s %s\n' "${RULE_ENGINE_A}" "${RULE_ENGINE_B}"
    return 0
  fi

  if [[ "${role_a}" == "STANDBY" && "${role_b}" == "ACTIVE" ]]; then
    printf '%s %s\n' "${RULE_ENGINE_B}" "${RULE_ENGINE_A}"
    return 0
  fi

  echo "Rule Engine 역할 불안정: ${RULE_ENGINE_A}=${role_a:-unknown}, ${RULE_ENGINE_B}=${role_b:-unknown}" >&2
  return 1
}

wait_rule_engine_pair() {
  local env_file="$1"
  local attempt
  local stable_count=0
  local pair
  local previous_pair=""

  RULE_ENGINE_STABLE_PAIR=""

  # 순간적인 exactly-one 상태가 아닌 동일 역할 조합의 연속 관찰.
  # 관찰 중 역할 교체 또는 조회 실패 발생 시 안정 횟수 초기화.
  for ((attempt = 1; attempt <= RULE_ENGINE_WAIT_ATTEMPTS; attempt++)); do
    pair="$(rule_engine_resolve_pair "${env_file}" || true)"

    if [[ -n "${pair}" && "${pair}" == "${previous_pair}" ]]; then
      stable_count=$((stable_count + 1))
    elif [[ -n "${pair}" ]]; then
      previous_pair="${pair}"
      stable_count=1
    else
      previous_pair=""
      stable_count=0
    fi

    if (( stable_count >= RULE_ENGINE_STABLE_CHECKS )); then
      RULE_ENGINE_STABLE_PAIR="${pair}"
      echo "Rule Engine 역할 안정화 확인: ${pair}"
      return 0
    fi

    if (( attempt < RULE_ENGINE_WAIT_ATTEMPTS )); then
      sleep "${RULE_ENGINE_WAIT_INTERVAL_SECONDS}"
    fi
  done

  echo "Rule Engine exactly-one-ACTIVE 확인 실패" >&2
  return 1
}

# 실행 중인 물리 인스턴스와 현재 역할을 기준으로 한 순차 배포 대상 결정.
#
# 0대: engine-a → engine-b 초기 기동
# A만 실행: 누락된 engine-b → 기존 engine-a
# B만 실행: 누락된 engine-a → 기존 engine-b
# 2대 실행: 현재 STANDBY → 반대편 물리 인스턴스
#
# 첫 재기동 뒤 역할 변경과 무관한 물리 인스턴스별 1회 교체 보장.
rule_engine_prepare_rollout() {
  local env_file="$1"
  local engine_a_running="$2"
  local engine_b_running="$3"
  local initial_active
  local initial_standby

  RULE_ENGINE_ROLLOUT_FIRST=""
  RULE_ENGINE_ROLLOUT_SECOND=""

  case "${engine_a_running}:${engine_b_running}" in
    0:0)
      RULE_ENGINE_ROLLOUT_FIRST="${RULE_ENGINE_A}"
      ;;
    1:0)
      RULE_ENGINE_ROLLOUT_FIRST="${RULE_ENGINE_B}"
      ;;
    0:1)
      RULE_ENGINE_ROLLOUT_FIRST="${RULE_ENGINE_A}"
      ;;
    1:1)
      wait_rule_engine_cluster "${env_file}" || return 1
      read -r initial_active initial_standby <<<"${RULE_ENGINE_STABLE_PAIR}"
      [[ -n "${initial_active}" && -n "${initial_standby}" ]] || return 1
      RULE_ENGINE_ROLLOUT_FIRST="${initial_standby}"
      ;;
    *)
      echo "Rule Engine 실행 상태가 올바르지 않습니다: engine-a=${engine_a_running}, engine-b=${engine_b_running}" >&2
      return 1
      ;;
  esac

  # 1차 대상의 반대편을 2차 대상으로 고정.
  # 역할 재조회 결과로 1차 대상을 다시 선택하는 중복 교체 방지.
  # shellcheck disable=SC2034
  RULE_ENGINE_ROLLOUT_SECOND="$(rule_engine_other_service "${RULE_ENGINE_ROLLOUT_FIRST}")" || return 1
}

# Compose 조회 실패와 미실행 상태를 구분.
# 반환값: 0=실행 중, 1=미실행, 2=조회 실패.
rule_engine_service_running() {
  local env_file="$1"
  local service="$2"
  local container_id

  container_id="$(rule_compose "${env_file}" ps -q --status running "${service}")" || {
    echo "Rule Engine 실행 상태 조회 실패: ${service}" >&2
    return 2
  }

  [[ -n "${container_id}" ]]
}

# Infra 전체 배포의 Rule A/B 순차 기동 실행.
# 호출 Script 요구사항: rule_engine_start <deploy-env> <service> Adapter.
rollout_rule_engine_infra() {
  local env_file="$1"
  local engine_a_running=0
  local engine_b_running=0
  local running_status
  local running_count
  local first_service
  local second_service

  if rule_engine_service_running "${env_file}" "${RULE_ENGINE_A}"; then
    engine_a_running=1
  else
    running_status=$?
    (( running_status == 1 )) || return "${running_status}"
  fi

  if rule_engine_service_running "${env_file}" "${RULE_ENGINE_B}"; then
    engine_b_running=1
  else
    running_status=$?
    (( running_status == 1 )) || return "${running_status}"
  fi

  running_count=$((engine_a_running + engine_b_running))

  rule_engine_prepare_rollout "${env_file}" "${engine_a_running}" "${engine_b_running}" || return 1
  first_service="${RULE_ENGINE_ROLLOUT_FIRST}"
  second_service="${RULE_ENGINE_ROLLOUT_SECOND}"

  rule_engine_start "${env_file}" "${first_service}" || return 1
  wait_rule_engine_registered "${env_file}" "${first_service#rule-}" || return 1

  # 기존 엔진이 하나 이상인 경우의 중간 exactly-one-ACTIVE 확인.
  # 0대 초기 기동의 첫 엔진만 존재하는 시점에는 Pair 검증 불가.
  if (( running_count > 0 )); then
    wait_rule_engine_cluster "${env_file}" || return 1
  fi

  rule_engine_start "${env_file}" "${second_service}" || return 1
  wait_rule_engine_registered "${env_file}" "${second_service#rule-}" || return 1
  wait_rule_engine_cluster "${env_file}" || return 1
}

wait_rule_engine_cluster() {
  local env_file="$1"

  # 최종 Cluster 성공 조건:
  # 1. engine-a Eureka 등록
  # 2. engine-b Eureka 등록
  # 3. 동일 exactly-one-ACTIVE 조합의 연속 관찰
  wait_rule_engine_registered "${env_file}" "engine-a" || return 1
  wait_rule_engine_registered "${env_file}" "engine-b" || return 1
  wait_rule_engine_pair "${env_file}" || return 1
}
