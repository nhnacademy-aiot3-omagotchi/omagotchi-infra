#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

usage() {
  echo "사용법: $0 [infra-directory] <40-character-commit-sha>" >&2
}

if (( $# == 1 )); then
  SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
  INFRA_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
  sha="$1"
elif (( $# == 2 )); then
  INFRA_DIR="$(cd -- "$1" && pwd)"
  sha="$2"
else
  usage
  exit 64
fi

if [[ ! "${sha}" =~ ^[0-9a-f]{40}$ ]]; then
  echo "인프라 revision은 소문자 16진수 40자리 commit SHA여야 합니다." >&2
  exit 64
fi

ROOT_DIR="$(cd -- "${INFRA_DIR}/.." && pwd)"
DEPLOY_ENV="${INFRA_DIR}/deploy.env"
SECRET_ENV="${ROOT_DIR}/secrets/prod.env"
COMPOSE_SCRIPT="${INFRA_DIR}/scripts/compose.sh"
SMOKE_SCRIPT="${INFRA_DIR}/scripts/smoke-test.sh"
RULE_ENGINE_SCRIPT="${INFRA_DIR}/scripts/rule-engine.sh"
LOCK_FILE="${ROOT_DIR}/.omagotchi-deploy.lock"

[[ -d "${INFRA_DIR}/.git" ]] || { echo "infra Git 저장소가 아닙니다: ${INFRA_DIR}" >&2; exit 1; }
[[ -f "${DEPLOY_ENV}" ]] || { echo "deploy.env가 없습니다." >&2; exit 1; }
[[ -f "${SECRET_ENV}" ]] || { echo "prod.env가 없습니다." >&2; exit 1; }
command -v flock >/dev/null 2>&1 || { echo "flock 명령이 없습니다." >&2; exit 1; }

# 서비스 이미지 배포와 인프라 배포가 같은 Compose 프로젝트를 동시에 바꾸지 않게 직렬화
exec 9>"${LOCK_FILE}"
flock -w 900 9 || { echo "다른 배포 대기 시간 초과" >&2; exit 1; }

cd "${INFRA_DIR}"

if [[ "$(git branch --show-current)" != "main" ]]; then
  echo "서버 infra 저장소가 main 브랜치가 아닙니다." >&2
  exit 1
fi

if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
  echo "서버 infra 저장소에 추적 파일 변경이 있어 자동 배포를 중단합니다." >&2
  exit 1
fi

old_sha="$(git rev-parse HEAD)"

git fetch \
  --no-tags \
  origin \
  refs/heads/main:refs/remotes/origin/main

git cat-file -e "${sha}^{commit}" 2>/dev/null || {
  echo "배포할 commit을 찾을 수 없습니다: ${sha}" >&2
  exit 1
}

git merge-base --is-ancestor "${sha}" origin/main || {
  echo "배포할 commit이 origin/main에 포함되어 있지 않습니다: ${sha}" >&2
  exit 1
}

git merge-base --is-ancestor "${old_sha}" "${sha}" || {
  echo "서버 상태에서 fast-forward할 수 없는 commit입니다: ${old_sha} -> ${sha}" >&2
  exit 1
}

git merge --ff-only "${sha}"

[[ -x "${COMPOSE_SCRIPT}" ]] || { echo "compose.sh 실행 권한이 없습니다." >&2; exit 1; }
[[ -x "${SMOKE_SCRIPT}" ]] || { echo "smoke-test.sh 실행 권한이 없습니다." >&2; exit 1; }
[[ -r "${RULE_ENGINE_SCRIPT}" ]] || { echo "rule-engine.sh를 읽을 수 없습니다." >&2; exit 1; }

compose() {
  DEPLOY_ENV_FILE="${DEPLOY_ENV}" \
    SECRET_ENV_FILE="${SECRET_ENV}" \
    "${COMPOSE_SCRIPT}" "$@"
}

# rule-engine.sh가 사용하는 Compose Adapter
rule_compose() {
  local env_file="$1"
  shift
  DEPLOY_ENV_FILE="${env_file}" \
    SECRET_ENV_FILE="${SECRET_ENV}" \
    "${COMPOSE_SCRIPT}" "$@"
}

# shellcheck disable=SC1090
source "${RULE_ENGINE_SCRIPT}"

compose config --quiet

rule_engine_start() {
  local _env_file="$1"
  local target_service="$2"

  compose up -d --no-deps --wait --wait-timeout 300 "${target_service}"
}

# Discovery를 먼저 반영한 뒤 모든 Client의 재등록 확인
compose up -d --no-deps --wait --wait-timeout 300 discovery-service
compose up \
  -d \
  --no-deps \
  --wait \
  --wait-timeout 300 \
  frontend \
  gateway-service \
  identity-service \
  learning-service

wait_eureka_application "${DEPLOY_ENV}" "FRONTEND"
wait_eureka_application "${DEPLOY_ENV}" "GATEWAY-SERVICE"
wait_eureka_application "${DEPLOY_ENV}" "IDENTITY-SERVICE"
wait_eureka_application "${DEPLOY_ENV}" "LEARNING-SERVICE"

# 이전 단일 rule-service 컨테이너 제거 후 A/B를 순차 기동
compose up -d --no-deps --remove-orphans discovery-service

rollout_rule_engine_infra "${DEPLOY_ENV}" || {
  echo "Rule Engine 순차 배포 실패. 일부 인스턴스가 갱신되었을 수 있으므로 A/B 상태와 이미지 태그를 확인하세요." >&2
  exit 1
}

compose up -d --no-deps --wait --wait-timeout 300 nginx cloudflared
"${SMOKE_SCRIPT}"

echo "인프라 배포 완료: ${old_sha} -> ${sha}"
