#!/usr/bin/env bash

# Rule Engine A/B 운영 확인 함수.
# 호출 스크립트는 rule_compose <deploy-env> <compose-args...> 함수를 제공해야 함.

RULE_ENGINE_A="rule-engine-a"
RULE_ENGINE_B="rule-engine-b"
RULE_ENGINE_WAIT_ATTEMPTS="${RULE_ENGINE_WAIT_ATTEMPTS:-36}"
RULE_ENGINE_WAIT_INTERVAL_SECONDS="${RULE_ENGINE_WAIT_INTERVAL_SECONDS:-5}"
RULE_ENGINE_STABLE_CHECKS="${RULE_ENGINE_STABLE_CHECKS:-3}"

rule_engine_role() {
  local env_file="$1"
  local service="$2"
  local response

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

wait_rule_engine_role() {
  local env_file="$1"
  local service="$2"
  local expected_role="$3"
  local attempt
  local actual_role

  for ((attempt = 1; attempt <= RULE_ENGINE_WAIT_ATTEMPTS; attempt++)); do
    actual_role="$(rule_engine_role "${env_file}" "${service}" || true)"
    if [[ "${actual_role}" == "${expected_role}" ]]; then
      echo "Rule Engine 역할 확인: ${service}=${expected_role}"
      return 0
    fi

    if (( attempt < RULE_ENGINE_WAIT_ATTEMPTS )); then
      sleep "${RULE_ENGINE_WAIT_INTERVAL_SECONDS}"
    fi
  done

  echo "Rule Engine 역할 확인 실패: ${service}, expected=${expected_role}, actual=${actual_role:-unknown}" >&2
  return 1
}

rule_engine_resolve_pair() {
  local env_file="$1"
  local role_a
  local role_b

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

  for ((attempt = 1; attempt <= RULE_ENGINE_WAIT_ATTEMPTS; attempt++)); do
    pair="$(rule_engine_resolve_pair "${env_file}" || true)"

    if [[ -n "${pair}" ]]; then
      stable_count=$((stable_count + 1))
      if (( stable_count >= RULE_ENGINE_STABLE_CHECKS )); then
        echo "Rule Engine 역할 안정화 확인: ${pair}"
        return 0
      fi
    else
      stable_count=0
    fi

    if (( attempt < RULE_ENGINE_WAIT_ATTEMPTS )); then
      sleep "${RULE_ENGINE_WAIT_INTERVAL_SECONDS}"
    fi
  done

  echo "Rule Engine exactly-one-ACTIVE 확인 실패" >&2
  return 1
}

wait_rule_engine_cluster() {
  local env_file="$1"

  wait_rule_engine_registered "${env_file}" "engine-a"
  wait_rule_engine_registered "${env_file}" "engine-b"
  wait_rule_engine_pair "${env_file}"
}
