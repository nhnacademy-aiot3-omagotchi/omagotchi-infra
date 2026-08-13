#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

# infra 기준 경로
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
ROOT_DIR="$(cd -- "${INFRA_DIR}/.." && pwd)"
DEPLOY_ENV="${INFRA_DIR}/deploy.env"
SECRET_ENV="${ROOT_DIR}/secrets/prod.env"
COMPOSE_SCRIPT="${SCRIPT_DIR}/compose.sh"
SMOKE_SCRIPT="${SCRIPT_DIR}/smoke-test.sh"
RULE_ENGINE_SCRIPT="${SCRIPT_DIR}/rule-engine.sh"
LOCK_FILE="${ROOT_DIR}/.omagotchi-deploy.lock"

usage() {
  echo "사용법: $0 <service> <40-character-commit-sha>" >&2
  echo "서비스: frontend | discovery-service | gateway-service | identity-service | learning-service | rule-service" >&2
}

# env 파일에서 지정한 값만 조회
read_env() {
  awk -F= -v key="$1" '
    $1 == key {
      print substr($0, index($0, "=") + 1)
      exit
    }
  ' "$2"
}

# 지정한 deploy env로 Compose 실행
compose() {
  local env_file="$1"
  shift
  DEPLOY_ENV_FILE="${env_file}" \
    SECRET_ENV_FILE="${SECRET_ENV}" \
    "${COMPOSE_SCRIPT}" "$@"
}

# rule-engine.sh가 사용하는 Compose Adapter
rule_compose() {
  compose "$@"
}

# 대상 서비스만 재생성하고 healthcheck 대기
start_service() {
  local env_file="$1"
  local target_service="$2"

  compose "${env_file}" up \
    -d \
    --no-deps \
    --force-recreate \
    --pull never \
    --wait \
    --wait-timeout 180 \
    "${target_service}"
}

# Frontend와 Gateway의 새 컨테이너 IP 반영
reload_nginx() {
  if [[ "${service}" != "frontend" && "${service}" != "gateway-service" ]]; then
    return 0
  fi

  compose "$1" exec -T nginx nginx -t
  compose "$1" exec -T nginx nginx -s reload
}

# Discovery 재기동 후 운영 Client 재등록 확인
wait_discovery_clients() {
  local env_file="$1"

  wait_eureka_application "${env_file}" "FRONTEND" || return 1
  wait_eureka_application "${env_file}" "GATEWAY-SERVICE" || return 1
  wait_eureka_application "${env_file}" "IDENTITY-SERVICE" || return 1
  wait_eureka_application "${env_file}" "LEARNING-SERVICE" || return 1
  wait_rule_engine_cluster "${env_file}" || return 1
}

# 실제 deploy.env에 기록된 이전 Rule 이미지로 순차 복구
restore_rule_engine() {
  local target_service="$1"

  if ! start_service "${DEPLOY_ENV}" "${target_service}"; then
    compose "${DEPLOY_ENV}" pull "${target_service}" || return 1
    start_service "${DEPLOY_ENV}" "${target_service}" || return 1
  fi
}

rollback_rule_service() {
  echo "이전 이미지로 복구: rule-service (${old_tag})" >&2

  if [[ "${rule_stage}" == "standby" || "${rule_stage}" == "active" ]]; then
    restore_rule_engine "${rule_standby_service}" || return 1
  fi

  if [[ "${rule_stage}" == "active" ]]; then
    restore_rule_engine "${rule_active_service}" || return 1
  fi

  wait_rule_engine_cluster "${DEPLOY_ENV}" || return 1
  "${SMOKE_SCRIPT}" "${base_url}"
}

# 실제 deploy.env에 기록된 이전 이미지로 복구
rollback() {
  if [[ "${service}" == "rule-service" ]]; then
    rollback_rule_service
    return
  fi

  echo "이전 이미지로 복구: ${service} (${old_tag})" >&2

  if ! start_service "${DEPLOY_ENV}" "${service}"; then
    compose "${DEPLOY_ENV}" pull "${service}" || return 1
    start_service "${DEPLOY_ENV}" "${service}" || return 1
  fi

  if [[ "${service}" == "discovery-service" ]]; then
    wait_discovery_clients "${DEPLOY_ENV}" || return 1
  fi

  reload_nginx "${DEPLOY_ENV}" || return 1
  "${SMOKE_SCRIPT}" "${base_url}"
}

# 새 이미지 전환 이후 실패 처리
fail_and_rollback() {
  echo "배포 실패: $1" >&2

  if rollback; then
    echo "이전 이미지 복구 완료" >&2
  else
    echo "자동 복구 실패. 서버 상태 확인 필요" >&2
  fi

  exit 1
}

deploy_service_main() {
# 서비스와 새 이미지 SHA 확인
if (( $# != 2 )); then
  usage
  exit 64
fi

service="$1"
sha="$2"

case "${service}" in
  frontend) tag_var="FRONTEND_IMAGE_TAG" ;;
  discovery-service) tag_var="DISCOVERY_IMAGE_TAG" ;;
  gateway-service) tag_var="GATEWAY_IMAGE_TAG" ;;
  identity-service) tag_var="IDENTITY_IMAGE_TAG" ;;
  learning-service) tag_var="LEARNING_IMAGE_TAG" ;;
  rule-service) tag_var="RULE_IMAGE_TAG" ;;
  *)
    usage
    exit 64
    ;;
esac

if [[ ! "${sha}" =~ ^[0-9a-f]{40}$ ]]; then
  echo "이미지 태그는 소문자 16진수 40자리 commit SHA여야 합니다." >&2
  exit 64
fi

[[ -f "${DEPLOY_ENV}" ]] || { echo "deploy.env가 없습니다." >&2; exit 1; }
[[ -f "${SECRET_ENV}" ]] || { echo "prod.env가 없습니다." >&2; exit 1; }
[[ -x "${COMPOSE_SCRIPT}" ]] || { echo "compose.sh 실행 권한이 없습니다." >&2; exit 1; }
[[ -x "${SMOKE_SCRIPT}" ]] || { echo "smoke-test.sh 실행 권한이 없습니다." >&2; exit 1; }
[[ -r "${RULE_ENGINE_SCRIPT}" ]] || { echo "rule-engine.sh를 읽을 수 없습니다." >&2; exit 1; }
command -v flock >/dev/null 2>&1 || { echo "flock 명령이 없습니다." >&2; exit 1; }

# shellcheck disable=SC1090
source "${RULE_ENGINE_SCRIPT}"

# 서로 다른 저장소의 동시 배포 방지
exec 9>"${LOCK_FILE}"
flock -w 900 9 || { echo "다른 배포 대기 시간 초과" >&2; exit 1; }

old_tag="$(read_env "${tag_var}" "${DEPLOY_ENV}")"
base_url="$(read_env SMOKE_BASE_URL "${DEPLOY_ENV}")"
rule_stage="none"
rule_active_service=""
rule_standby_service=""

[[ "${old_tag}" =~ ^[0-9a-f]{40}$ ]] || { echo "기존 이미지 태그가 올바르지 않습니다." >&2; exit 1; }
[[ "${base_url}" =~ ^https?://[^[:space:]]+$ ]] || { echo "SMOKE_BASE_URL이 올바르지 않습니다." >&2; exit 1; }

# 새 태그를 반영한 임시 deploy env 생성
candidate="$(mktemp "${ROOT_DIR}/.deploy.env.candidate.XXXXXX")"
trap '[[ -n "${candidate:-}" ]] && rm -f "${candidate}"' EXIT

awk -F= -v key="${tag_var}" -v value="${sha}" '
  $1 == key {
    print key "=" value
    next
  }
  { print }
' "${DEPLOY_ENV}" >"${candidate}"

# 후보 설정 검증 후 새 이미지 전환
compose "${candidate}" config --quiet

if [[ "${service}" == "rule-service" ]]; then
  current_pair="$(rule_engine_resolve_pair "${DEPLOY_ENV}")" || {
    echo "배포 전 Rule Engine 역할이 안정적이지 않아 배포를 중단합니다." >&2
    exit 1
  }
  read -r rule_active_service rule_standby_service <<<"${current_pair}"

  if ! compose "${candidate}" pull "${RULE_ENGINE_A}" "${RULE_ENGINE_B}"; then
    echo "새 이미지 pull 실패. 기존 컨테이너 유지" >&2
    exit 1
  fi

  rule_stage="standby"
  start_service "${candidate}" "${rule_standby_service}" || fail_and_rollback "STANDBY 후보 healthcheck 실패"
  wait_rule_engine_registered "${candidate}" "${rule_standby_service#rule-}" || fail_and_rollback "STANDBY 후보 Eureka 등록 실패"
  wait_rule_engine_role "${candidate}" "${rule_standby_service}" "STANDBY" || fail_and_rollback "STANDBY 역할 안정화 실패"

  rule_stage="active"
  start_service "${candidate}" "${rule_active_service}" || fail_and_rollback "나머지 Rule Engine healthcheck 실패"
  wait_rule_engine_cluster "${candidate}" || fail_and_rollback "Rule Engine exactly-one-ACTIVE 검증 실패"
else
  if ! compose "${candidate}" pull "${service}"; then
    echo "새 이미지 pull 실패. 기존 컨테이너 유지" >&2
    exit 1
  fi

  start_service "${candidate}" "${service}" || fail_and_rollback "컨테이너 healthcheck 실패"

  if [[ "${service}" == "discovery-service" ]]; then
    wait_discovery_clients "${candidate}" || fail_and_rollback "Discovery Client 재등록 실패"
  fi
fi

reload_nginx "${candidate}" || fail_and_rollback "Nginx reload 실패"
"${SMOKE_SCRIPT}" "${base_url}" || fail_and_rollback "Smoke Test 실패"

# 모든 검증 성공 후 deploy.env 갱신
if ! mv -f "${candidate}" "${DEPLOY_ENV}"; then
  fail_and_rollback "deploy.env 갱신 실패"
fi
candidate=""

echo "배포 완료: ${service} (${sha})"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  deploy_service_main "$@"
fi
