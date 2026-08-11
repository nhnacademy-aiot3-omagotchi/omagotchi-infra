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

# 대상 서비스만 재생성하고 healthcheck 대기
start_service() {
  compose "$1" up \
    -d \
    --no-deps \
    --force-recreate \
    --pull never \
    --wait \
    --wait-timeout 180 \
    "${service}"
}

# Frontend와 Gateway의 새 컨테이너 IP 반영
reload_nginx() {
  if [[ "${service}" != "frontend" && "${service}" != "gateway-service" ]]; then
    return 0
  fi

  compose "$1" exec -T nginx nginx -t
  compose "$1" exec -T nginx nginx -s reload
}

# 실제 deploy.env에 기록된 이전 이미지로 복구
rollback() {
  echo "이전 이미지로 복구: ${service} (${old_tag})" >&2

  if ! start_service "${DEPLOY_ENV}"; then
    compose "${DEPLOY_ENV}" pull "${service}" || return 1
    start_service "${DEPLOY_ENV}" || return 1
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
command -v flock >/dev/null 2>&1 || { echo "flock 명령이 없습니다." >&2; exit 1; }

# 서로 다른 저장소의 동시 배포 방지
exec 9>"${LOCK_FILE}"
flock -w 900 9 || { echo "다른 배포 대기 시간 초과" >&2; exit 1; }

old_tag="$(read_env "${tag_var}" "${DEPLOY_ENV}")"
base_url="$(read_env SMOKE_BASE_URL "${DEPLOY_ENV}")"

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

if ! compose "${candidate}" pull "${service}"; then
  echo "새 이미지 pull 실패. 기존 컨테이너 유지" >&2
  exit 1
fi

start_service "${candidate}" || fail_and_rollback "컨테이너 healthcheck 실패"
reload_nginx "${candidate}" || fail_and_rollback "Nginx reload 실패"
"${SMOKE_SCRIPT}" "${base_url}" || fail_and_rollback "Smoke Test 실패"

# 모든 검증 성공 후 deploy.env 갱신
if ! mv -f "${candidate}" "${DEPLOY_ENV}"; then
  fail_and_rollback "deploy.env 갱신 실패"
fi
candidate=""

echo "배포 완료: ${service} (${sha})"
