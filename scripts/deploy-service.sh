#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

# 서비스별 이미지 교체 진입점.
#
# 핵심 불변 조건:
# - 일반 앱: rolling_deploy로 A/B 순차 교체, 검증을 마친 슬롯별 SHA 기록
# - 일반 앱의 논리 SHA: A/B 전체 성공 후 확정
# - Rule·Discovery: 후보 파일로 배포·검증, 전체 성공 후 deploy.env 교체
# - Rule: 기존 ACTIVE/STANDBY 순서 유지, 두 Container의 동시 교체 금지

# Infra 저장소와 저장소 외부 운영 파일의 기준 경로.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
ROOT_DIR="$(cd -- "${INFRA_DIR}/.." && pwd)"
DEPLOY_ENV="${INFRA_DIR}/deploy.env"
SECRET_ENV="${ROOT_DIR}/secrets/prod.env"
COMPOSE_SCRIPT="${SCRIPT_DIR}/compose.sh"
SMOKE_SCRIPT="${SCRIPT_DIR}/smoke-test.sh"
RULE_ENGINE_SCRIPT="${SCRIPT_DIR}/rule-engine.sh"
LOCK_FILE="${ROOT_DIR}/.omagotchi-deploy.lock"
# 여러 저장소의 연속 배포를 위한 최대 30분 대기. 잠금 획득 후의 실행 시간과 별개.
DEPLOY_LOCK_WAIT_SECONDS=1800

usage() {
  echo "사용법: $0 <service> <40-character-commit-sha>" >&2
  echo "Rule 누락 인스턴스 복구: $0 rule-service --recover" >&2
  echo "서비스: frontend | discovery-service | gateway-service | identity-service | learning-service | rule-service | prediction-service" >&2
}

# 제한 시간 대기 방식의 배포 File Lock 획득.
acquire_deploy_lock() {
  local lock_file="$1"
  local wait_seconds="$2"
  local operation_name="$3"
  local lock_status

  command -v flock >/dev/null 2>&1 || {
    echo "flock 명령이 없습니다." >&2
    return 1
  }

  echo "배포 잠금 대기 시작 (${operation_name}): 최대 ${wait_seconds}초"
  exec 9>"${lock_file}"

  if flock -w "${wait_seconds}" -E 75 9; then
    echo "배포 잠금 획득 (${operation_name})"
    return 0
  else
    lock_status=$?
  fi

  if ((lock_status == 75)); then
    echo "배포 잠금 획득 시간 초과 (${operation_name}): ${wait_seconds}초" >&2
  else
    echo "배포 잠금 획득 실패 (${operation_name}): flock 종료 코드 ${lock_status}" >&2
  fi
  return 1
}

# 대상 Container 하나의 강제 재생성과 Healthcheck 대기.
# 사전 Pull 완료를 전제로 한 --pull never 사용.
start_service() {
  local env_file="$1"
  local target_service="$2"

  rolling_compose "${env_file}" up \
    -d \
    --no-deps \
    --force-recreate \
    --pull never \
    --wait \
    --wait-timeout 180 \
    "${target_service}" || return 1
}

# Discovery 교체 완료 조건.
# Eureka 등록 대상 서비스와 Rule A/B의 재등록·역할 안정화 확인.
# Frontend는 Registry 조회만 수행하고 register-with-eureka=false이므로 확인 대상 제외.
wait_discovery_clients() {
  local env_file="$1"

  wait_eureka_application "${env_file}" "GATEWAY-SERVICE" || return 1
  wait_eureka_application "${env_file}" "IDENTITY-SERVICE" || return 1
  wait_eureka_application "${env_file}" "LEARNING-SERVICE" || return 1
  wait_rule_engine_cluster "${env_file}" || return 1
}

# Discovery 복구 또는 Rule 전용 복구 위임. 일반 앱의 복구는 rolling_deploy의 담당.
rollback() {
  if [[ "${service}" == "rule-service" ]]; then
    rollback_rule_service "${old_tag}" "${base_url}"
    return
  fi

  echo "이전 이미지로 복구: ${service} (${old_tag})" >&2

  if ! start_service "${DEPLOY_ENV}" "${service}"; then
    rolling_compose "${DEPLOY_ENV}" pull "${service}" || return 1
    start_service "${DEPLOY_ENV}" "${service}" || return 1
  fi

  wait_discovery_clients "${DEPLOY_ENV}" || return 1
  "${SMOKE_SCRIPT}" "${base_url}"
}

# 새 이미지 전환 이후 공통 실패 종착점.
# Rollback 결과 출력 후 항상 실패 종료.
fail_and_rollback() {
  echo "배포 실패: $1" >&2

  if rollback; then
    echo "이전 이미지 복구 완료" >&2
  else
    echo "자동 복구 실패. 서버 상태 확인 필요" >&2
  fi

  exit 1
}

# 배포 완료 서비스의 오래된 로컬 SHA 이미지 정리.
# 현재·직전 성공 이미지와 실행·중지 상태 Container의 참조 이미지 보존.
# 호출 조건: 공용 배포 Lock 보유 및 deploy.env 확정 완료.
cleanup_service_images() {
  local target_service="$1"
  local current_sha="$2"
  local previous_sha="$3"
  local repository current_id previous_id images reference image_id containers

  case "${target_service}" in
  frontend | discovery-service | gateway-service | identity-service | learning-service | rule-service | prediction-service) ;;
  *) return 1 ;;
  esac
  [[ "${current_sha}" =~ ^[0-9a-f]{40}$ && "${previous_sha}" =~ ^[0-9a-f]{40}$ ]] || return 1

  # 같은 SHA 재배포 시 직전의 다른 성공 SHA를 알 수 없으므로 정리 생략.
  [[ "${current_sha}" != "${previous_sha}" ]] || return 0
  repository="ghcr.io/nhnacademy-aiot3-omagotchi/omagotchi-${target_service}"

  # 보존 대상 조회 실패 시 삭제 중단. 같은 Image ID의 다른 태그도 보존.
  current_id="$(docker image inspect --format '{{.Id}}' "${repository}:${current_sha}")" || return 1
  previous_id="$(docker image inspect --format '{{.Id}}' "${repository}:${previous_sha}")" || return 1
  [[ "${current_id}" =~ ^sha256:[0-9a-f]{64}$ && "${previous_id}" =~ ^sha256:[0-9a-f]{64}$ ]] || return 1
  images="$(docker image ls --no-trunc --filter "reference=${repository}:*" \
    --format '{{.Repository}}:{{.Tag}} {{.ID}}')" || return 1

  while read -r reference image_id; do
    # 정확한 팀 저장소의 SHA 태그만 대상. main·수동 태그·태그 없는 이미지 제외.
    [[ "${reference%:*}" == "${repository}" && "${reference##*:}" =~ ^[0-9a-f]{40}$ ]] || continue
    [[ "${image_id}" =~ ^sha256:[0-9a-f]{64}$ ]] || return 1
    [[ "${image_id}" != "${current_id}" && "${image_id}" != "${previous_id}" ]] || continue

    # 다른 프로젝트와 중지된 Container도 포함한 참조 확인.
    containers="$(docker container ls --all --quiet --filter "ancestor=${image_id}")" || return 1
    [[ -z "${containers}" ]] || continue

    echo "이전 서비스 이미지 정리: ${reference}"
    # 태그 단위 삭제. 강제 삭제와 태그 없는 상위 이미지의 연쇄 삭제 제외.
    docker image rm --no-prune "${reference}" || return 1
  done <<<"${images}"
}

deploy_service_main() {
  # 논리 서비스명과 GHCR 이미지 태그로 사용하는 Commit SHA 검증.
  if (($# != 2)); then
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
  prediction-service) tag_var="PREDICTION_IMAGE_TAG" ;;
  *)
    usage
    exit 64
    ;;
  esac

  if [[ "${sha}" == --recover && "${service}" != rule-service ]]; then
    usage
    exit 64
  fi
  if [[ "${sha}" != --recover && ! "${sha}" =~ ^[0-9a-f]{40}$ ]]; then
    echo "이미지 태그는 소문자 16진수 40자리 commit SHA여야 합니다." >&2
    exit 64
  fi

  [[ -f "${DEPLOY_ENV}" ]] || {
    echo "deploy.env가 없습니다." >&2
    exit 1
  }
  [[ -f "${SECRET_ENV}" ]] || {
    echo "prod.env가 없습니다." >&2
    exit 1
  }
  [[ -x "${COMPOSE_SCRIPT}" ]] || {
    echo "compose.sh 실행 권한이 없습니다." >&2
    exit 1
  }
  [[ -x "${SMOKE_SCRIPT}" ]] || {
    echo "smoke-test.sh 실행 권한이 없습니다." >&2
    exit 1
  }
  [[ -r "${RULE_ENGINE_SCRIPT}" ]] || {
    echo "rule-engine.sh를 읽을 수 없습니다." >&2
    exit 1
  }
  # 전체 Infra 배포와 다른 서비스별 배포의 동시 실행 차단.
  acquire_deploy_lock \
    "${LOCK_FILE}" \
    "${DEPLOY_LOCK_WAIT_SECONDS}" \
    "서비스 배포: ${service}" || exit 1

  # 공용 잠금 획득 이후 서버의 배포 함수 로드.
  # shellcheck disable=SC1090
  source "${RULE_ENGINE_SCRIPT}"
  # shellcheck disable=SC1091
  source "${SCRIPT_DIR}/rolling-deploy.sh"

  if [[ "${sha}" == --recover ]]; then
    rolling_compose "${DEPLOY_ENV}" config --quiet || return 1
    recover_rule_service "${DEPLOY_ENV}" || return 1
    "${SMOKE_SCRIPT}" "$(rolling_read SMOKE_BASE_URL "${DEPLOY_ENV}")" || return 1
    echo "Rule 누락 인스턴스 복구 완료"
    return
  fi

  if [[ "${service}" != rule-service && "${service}" != discovery-service ]]; then
    # 대상 서비스의 A/B 교체와 성공 이미지 정리.
    rolling_initialize_routes || exit 1
    old_tag="$(rolling_read "${tag_var}" "${DEPLOY_ENV}")"
    rolling_deploy "${service}" "${sha}" || return 1
    if ! cleanup_service_images "${service}" "${sha}" "${old_tag}"; then
      echo "경고: 이전 이미지 정리 실패. 성공한 A/B 배포 상태 유지" >&2
    fi
    return
  fi

  old_tag="$(rolling_read "${tag_var}" "${DEPLOY_ENV}")"
  base_url="$(rolling_read SMOKE_BASE_URL "${DEPLOY_ENV}")"

  [[ "${old_tag}" =~ ^[0-9a-f]{40}$ ]] || {
    echo "기존 이미지 태그가 올바르지 않습니다." >&2
    exit 1
  }
  [[ "${base_url}" =~ ^https?://[^[:space:]]+$ ]] || {
    echo "SMOKE_BASE_URL이 올바르지 않습니다." >&2
    exit 1
  }

  # 기존 deploy.env를 보존한 후보 상태 생성.
  # Script 종료 시 미확정 후보 파일의 자동 폐기.
  candidate="$(mktemp "${ROOT_DIR}/.deploy.env.candidate.XXXXXX")"
  trap '[[ -n "${candidate:-}" ]] && rm -f "${candidate}"' EXIT

  awk -F= -v key="${tag_var}" -v value="${sha}" '
  $1 == key {
    print key "=" value
    next
  }
  { print }
' "${DEPLOY_ENV}" >"${candidate}"

  # 실제 Container 변경 전 후보 Compose 설정의 완전한 해석 확인.
  rolling_compose "${candidate}" config --quiet

  if [[ "${service}" == "rule-service" ]]; then
    deploy_rule_service "${candidate}" || exit 1
  else
    if ! rolling_compose "${candidate}" pull "${service}"; then
      echo "새 이미지 pull 실패. 기존 컨테이너 유지" >&2
      exit 1
    fi

    start_service "${candidate}" "${service}" || fail_and_rollback "컨테이너 healthcheck 실패"

    wait_discovery_clients "${candidate}" || fail_and_rollback "Discovery Client 재등록 실패"
  fi

  "${SMOKE_SCRIPT}" "${base_url}" || fail_and_rollback "Smoke Test 실패"

  # 모든 검증 성공 이후 후보 상태의 확정.
  # 동일 File System 내부 mv를 이용한 중간 내용 노출 방지.
  if ! mv -f "${candidate}" "${DEPLOY_ENV}"; then
    fail_and_rollback "deploy.env 갱신 실패"
  fi
  candidate=""

  echo "배포 완료: ${service} (${sha})"

  # 부가 정리 실패 시 성공한 배포 유지, 다음 새 SHA 배포에서 정리 재시도.
  if ! cleanup_service_images "${service}" "${sha}" "${old_tag}"; then
    echo "경고: 이전 이미지 정리 실패. 배포 상태 유지, 정리 결과 확인 필요" >&2
  fi
}

# 테스트 source 시 main 미실행, 직접 실행 시에만 실제 배포 시작.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  deploy_service_main "$@"
fi
