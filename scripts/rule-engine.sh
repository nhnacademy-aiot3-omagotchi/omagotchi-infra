#!/usr/bin/env bash

# Rule A/B의 역할 확인·순차 배포·실패 복구. deploy-service.sh에서 로드.
# Compose·Eureka·Nginx 공통 조작은 rolling-deploy.sh 함수 사용.
# Rule 배포 중 공유 상태: rule_stage·1차/2차 물리 대상. 실패 복구 시 같은 상태 사용.

RULE_ENGINE_A="rule-engine-a"
RULE_ENGINE_B="rule-engine-b"
# 최대 대기 시간: 기본 36회 × 5초.
# 안정 상태: 동일 ACTIVE/STANDBY 조합의 기본 3회 연속 관찰.
RULE_ENGINE_WAIT_ATTEMPTS="${RULE_ENGINE_WAIT_ATTEMPTS:-36}"
RULE_ENGINE_WAIT_INTERVAL_SECONDS="${RULE_ENGINE_WAIT_INTERVAL_SECONDS:-5}"
RULE_ENGINE_STABLE_CHECKS="${RULE_ENGINE_STABLE_CHECKS:-3}"

# 환경변수 오입력으로 대기·안정화 검증이 무력화되는 상태 차단.
rule_engine_validate_wait_config() {
  if [[ ! "${RULE_ENGINE_WAIT_ATTEMPTS}" =~ ^[0-9]+$ ]] ||
    ((RULE_ENGINE_WAIT_ATTEMPTS < 1)); then
    echo "RULE_ENGINE_WAIT_ATTEMPTS는 1 이상의 정수여야 합니다." >&2
    return 1
  fi

  if [[ ! "${RULE_ENGINE_WAIT_INTERVAL_SECONDS}" =~ ^[0-9]+$ ]]; then
    echo "RULE_ENGINE_WAIT_INTERVAL_SECONDS는 0 이상의 정수여야 합니다." >&2
    return 1
  fi

  if [[ ! "${RULE_ENGINE_STABLE_CHECKS}" =~ ^[0-9]+$ ]] ||
    ((RULE_ENGINE_STABLE_CHECKS < 1)); then
    echo "RULE_ENGINE_STABLE_CHECKS는 1 이상의 정수여야 합니다." >&2
    return 1
  fi

  if ((RULE_ENGINE_STABLE_CHECKS > RULE_ENGINE_WAIT_ATTEMPTS)); then
    echo "RULE_ENGINE_STABLE_CHECKS는 RULE_ENGINE_WAIT_ATTEMPTS 이하여야 합니다." >&2
    return 1
  fi
}

rule_engine_validate_wait_config || {
  if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    exit 1
  fi
  return 1
}
# 함수 결과 공유용 전역 상태.
# 상태 확인 함수의 진행 로그와 계산 결과를 함께 보존하기 위한 stdout 반환 미사용.
RULE_ENGINE_STABLE_PAIR=""    # "ACTIVE 서비스 STANDBY 서비스"
RULE_ENGINE_ROLLOUT_FIRST=""  # 먼저 교체할 물리 Compose 서비스
RULE_ENGINE_ROLLOUT_SECOND="" # 나중에 교체할 물리 Compose 서비스

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
    rolling_compose "${env_file}" exec -T --interactive=false "${service}" sh -ec '
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
    rolling_compose "${env_file}" exec -T --interactive=false discovery-service \
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
  rolling_compose "${env_file}" exec -T --interactive=false discovery-service \
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

    if ((attempt < RULE_ENGINE_WAIT_ATTEMPTS)); then
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

    if ((attempt < RULE_ENGINE_WAIT_ATTEMPTS)); then
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

    if ((stable_count >= RULE_ENGINE_STABLE_CHECKS)); then
      RULE_ENGINE_STABLE_PAIR="${pair}"
      echo "Rule Engine 역할 안정화 확인: ${pair}"
      return 0
    fi

    if ((attempt < RULE_ENGINE_WAIT_ATTEMPTS)); then
      sleep "${RULE_ENGINE_WAIT_INTERVAL_SECONDS}"
    fi
  done

  echo "Rule Engine exactly-one-ACTIVE 확인 실패" >&2
  return 1
}

# 안정된 A/B의 STANDBY 우선 교체 순서. 첫 교체 후 역할이 바뀌어도 물리 대상 유지.
rule_engine_prepare_rollout() {
  local env_file="$1" initial_active initial_standby
  RULE_ENGINE_ROLLOUT_FIRST=""
  RULE_ENGINE_ROLLOUT_SECOND=""
  wait_rule_engine_cluster "${env_file}" || return 1
  read -r initial_active initial_standby <<<"${RULE_ENGINE_STABLE_PAIR}"
  [[ -n "${initial_active}" && -n "${initial_standby}" ]] || return 1
  RULE_ENGINE_ROLLOUT_FIRST="${initial_standby}"
  RULE_ENGINE_ROLLOUT_SECOND="$(rule_engine_other_service "${initial_standby}")" || return 1
}

# Compose 조회 실패와 미실행 상태를 구분.
# 반환값: 0=실행 중, 1=미실행, 2=조회 실패.
rule_engine_service_running() {
  local env_file="$1"
  local service="$2"
  local container_id

  container_id="$(rolling_compose "${env_file}" ps -q --status running "${service}")" || {
    echo "Rule Engine 실행 상태 조회 실패: ${service}" >&2
    return 2
  }

  [[ -n "${container_id}" ]]
}

# 누락되거나 종료된 Rule 인스턴스의 명시적 복구. 실행 중인 인스턴스는 유지.
# 현재 deploy.env의 이미지 사용, 실패 시 이미 복원한 인스턴스 유지.
recover_rule_service() {
  local env_file="$1" target status
  local missing=()
  # 변경 전 두 인스턴스의 조회 완료. 조회 실패를 미실행으로 취급하지 않음.
  for target in "${RULE_ENGINE_A}" "${RULE_ENGINE_B}"; do
    if rule_engine_service_running "${env_file}" "${target}"; then
      continue
    else
      status=$?
      ((status == 1)) || return "${status}"
    fi
    missing+=("${target}")
  done
  for target in "${missing[@]}"; do
    rolling_compose "${env_file}" pull "${target}" || return 1
    start_rule_engine "${env_file}" "${target}" || return 1
    wait_rule_engine_registered "${env_file}" "${target#rule-}" || return 1
  done
  wait_rule_engine_cluster "${env_file}"
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

# Rule HTTP 요청 제외·교체·복귀. ACTIVE/STANDBY 순서는 상위 배포 함수에서 결정.
start_rule_engine() {
  local env_file="$1" target="$2"
  if rolling_ready "${target}"; then
    rolling_drain rule-service "${target}" || return 1
  fi
  start_service "${env_file}" "${target}" || return 1
  rolling_admit rule-service "${target}"
}

# deploy.env의 기존 Rule 이미지로 물리 인스턴스 1개 복구.
# 첫 복구 실패 시 기존 이미지 Pull 후 한 차례 재시도.
restore_rule_engine() {
  local target_service="$1"

  if ! start_rule_engine "${DEPLOY_ENV}" "${target_service}"; then
    rolling_compose "${DEPLOY_ENV}" pull "${target_service}" || return 1
    start_rule_engine "${DEPLOY_ENV}" "${target_service}" || return 1
  fi
}

rollback_rule_service() {
  local old_tag="$1" base_url="$2" rollback_failed=0

  echo "이전 이미지로 복구: rule-service (${old_tag})" >&2

  # rule_stage 상태:
  # - none: Container 변경 전
  # - first: 1차 물리 인스턴스 변경 이후
  # - second: 2차 물리 인스턴스 변경 이후
  # 복구 순서: 마지막 변경 인스턴스부터 역순 복구.
  if [[ "${rule_stage}" == "second" ]]; then
    # 마지막으로 변경한 인스턴스를 먼저 복구해, 1차 교체 인스턴스의 가용성을 유지.
    if ! restore_rule_engine "${rule_second_service}"; then
      echo "2차 Rule Engine 복구 실패: ${rule_second_service}" >&2
      rollback_failed=1
    fi
  fi

  if [[ "${rule_stage}" == "first" || "${rule_stage}" == "second" ]]; then
    if ! restore_rule_engine "${rule_first_service}"; then
      echo "1차 Rule Engine 복구 실패: ${rule_first_service}" >&2
      rollback_failed=1
    fi
  fi

  # 일부 복구 실패에도 나머지 복구 시도 완료 후 최종 상태 판정.
  if ! wait_rule_engine_cluster "${DEPLOY_ENV}"; then
    rollback_failed=1
  fi

  if ! "${SMOKE_SCRIPT}" "${base_url}"; then
    rollback_failed=1
  fi

  ((rollback_failed == 0))
}

deploy_rule_service() {
  local candidate="$1"
  local engine_a_running=0
  local engine_b_running=0
  local running_status

  rule_stage="none"
  rule_first_service=""
  rule_second_service=""

  # 서비스별 Rule 배포의 선행 조건: 두 물리 인스턴스 모두 실행 중.
  # 0대·1대 상태는 --recover 명시적 복구 후 배포.
  if rule_engine_service_running "${DEPLOY_ENV}" "${RULE_ENGINE_A}"; then
    engine_a_running=1
  else
    running_status=$?
    ((running_status == 1)) || return "${running_status}"
  fi

  if rule_engine_service_running "${DEPLOY_ENV}" "${RULE_ENGINE_B}"; then
    engine_b_running=1
  else
    running_status=$?
    ((running_status == 1)) || return "${running_status}"
  fi

  if ((engine_a_running != 1 || engine_b_running != 1)); then
    echo "Rule Engine 물리 인스턴스 2대가 실행 중이 아닙니다. deploy-service.sh rule-service --recover로 먼저 복구하십시오." >&2
    return 1
  fi

  rule_engine_prepare_rollout "${DEPLOY_ENV}" || {
    echo "배포 전 Rule Engine 역할이 안정적이지 않아 배포를 중단합니다." >&2
    return 1
  }

  rule_first_service="${RULE_ENGINE_ROLLOUT_FIRST}"
  rule_second_service="${RULE_ENGINE_ROLLOUT_SECOND}"

  if ! rolling_compose "${candidate}" pull "${RULE_ENGINE_A}" "${RULE_ENGINE_B}"; then
    echo "새 이미지 pull 실패. 기존 컨테이너 유지" >&2
    return 1
  fi

  # 1차 대상: 배포 시작 시점의 STANDBY 물리 인스턴스.
  rule_stage="first"
  start_rule_engine "${candidate}" "${rule_first_service}" || fail_and_rollback "1차 Rule Engine healthcheck 실패"
  wait_rule_engine_registered "${candidate}" "${rule_first_service#rule-}" || fail_and_rollback "1차 Rule Engine Eureka 등록 실패"
  wait_rule_engine_cluster "${candidate}" || fail_and_rollback "1차 교체 후 exactly-one-ACTIVE 검증 실패"

  # 첫 재기동 이후 ACTIVE/STANDBY 교체 가능성.
  # 2차 대상: 현재 역할명이 아니라 아직 갱신하지 않은 반대편 물리 인스턴스.
  rule_stage="second"
  start_rule_engine "${candidate}" "${rule_second_service}" || fail_and_rollback "2차 Rule Engine healthcheck 실패"
  wait_rule_engine_registered "${candidate}" "${rule_second_service#rule-}" || fail_and_rollback "2차 Rule Engine Eureka 등록 실패"
  wait_rule_engine_cluster "${candidate}" || fail_and_rollback "Rule Engine exactly-one-ACTIVE 검증 실패"
}
