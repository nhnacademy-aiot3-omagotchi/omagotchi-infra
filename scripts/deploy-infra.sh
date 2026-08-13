#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

# Infra 전체 구성 배포 진입점.
#
# 처리 순서:
# 1. 서버 Infra 저장소의 main Fast-forward
# 2. Compose 설정 검증
# 3. Discovery 선행 배포와 Eureka Client 재등록 확인
# 4. Rule Engine A/B 순차 배포와 역할 안정화 확인
#    --skip-rule 수동 배포에서는 Rule Container와 기존 상태를 변경하지 않음
# 5. Nginx·Cloudflare 기동과 외부 Smoke Test
#
# 실패 범위:
# - 실패 즉시 중단과 현재 단계 출력
# - Git checkout·이미 갱신된 Container의 전체 자동 Rollback 미제공
# - 최초 운영 배포 중 작업자 확인과 수동 복구를 전제로 한 구조

usage() {
  echo "사용법: $0 [--skip-rule] <infra-directory> <40-character-commit-sha>" >&2
}

# Rule 구현 완료 전 최초 운영 환경 확인용 수동 부분 배포.
# 기본값은 전체 배포이며 GitHub Actions도 이 옵션을 전달하지 않음.
skip_rule=false
if [[ "${1:-}" == "--skip-rule" ]]; then
  skip_rule=true
  shift
fi

# 대상 경로와 Revision의 암묵적 추론 금지.
# GitHub Actions와 수동 배포 모두 두 값을 명시적으로 전달.
if (( $# != 2 )); then
  usage
  exit 64
fi

INFRA_DIR="$(cd -- "$1" && pwd)"
sha="$2"

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

base_url="$(awk -F= '$1 == "SMOKE_BASE_URL" { print substr($0, index($0, "=") + 1); exit }' "${DEPLOY_ENV}")"
if [[ ! "${base_url}" =~ ^https?://[^[:space:]]+$ ]]; then
  echo "deploy.env의 SMOKE_BASE_URL이 올바르지 않습니다." >&2
  exit 1
fi

# 전체 Infra 배포와 서비스별 배포의 동시 실행 차단.
# 동일 Lock File을 사용하는 deploy-service.sh와의 상호 배제.
exec 9>"${LOCK_FILE}"
flock -n 9 || { echo "다른 배포가 진행 중이므로 즉시 중단합니다." >&2; exit 1; }

cd "${INFRA_DIR}"

if [[ "$(git branch --show-current)" != "main" ]]; then
  echo "서버 infra 저장소가 main 브랜치가 아닙니다." >&2
  exit 1
fi

if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
  echo "서버 infra 저장소에 추적 파일 변경이 있어 자동 배포를 중단합니다." >&2
  exit 1
fi

# 실패 메시지와 배포 완료 기록을 위한 배포 전 Revision 보존.
old_sha="$(git rev-parse HEAD)"

git fetch \
  --no-tags \
  origin \
  refs/heads/main:refs/remotes/origin/main

# 임의 SHA·다른 브랜치 SHA·서버 상태의 역행 배포 차단.
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

# Workflow가 실행된 main SHA와 서버의 실제 Script·Compose 파일 일치.
git merge --ff-only "${sha}"

[[ -x "${COMPOSE_SCRIPT}" ]] || { echo "compose.sh 실행 권한이 없습니다." >&2; exit 1; }
[[ -x "${SMOKE_SCRIPT}" ]] || { echo "smoke-test.sh 실행 권한이 없습니다." >&2; exit 1; }
[[ -r "${RULE_ENGINE_SCRIPT}" ]] || { echo "rule-engine.sh를 읽을 수 없습니다." >&2; exit 1; }

# 실제 deploy.env를 사용하는 전체 Infra Compose Adapter.
compose() {
  DEPLOY_ENV_FILE="${DEPLOY_ENV}" \
    SECRET_ENV_FILE="${SECRET_ENV}" \
    "${COMPOSE_SCRIPT}" "$@"
}

# rule-engine.sh가 전달받은 env 파일로 상태를 조회하기 위한 Adapter.
rule_compose() {
  local env_file="$1"
  shift
  DEPLOY_ENV_FILE="${env_file}" \
    SECRET_ENV_FILE="${SECRET_ENV}" \
    "${COMPOSE_SCRIPT}" "$@"
}

# shellcheck disable=SC1090
source "${RULE_ENGINE_SCRIPT}"

# Container 변경 전 Compose 변수 치환·구문·필수값 검증.
compose config --quiet

# rule-engine.sh의 순서 계산과 실제 Compose 기동의 경계.
# 순서 판단은 Library, Container 변경은 이 Script의 책임.
rule_engine_start() {
  local _env_file="$1"
  local target_service="$2"

  compose up -d --no-deps --wait --wait-timeout 300 "${target_service}"
}

# Discovery 선행 배포.
# 새 Registry 기동 전 Client 동시 재기동으로 인한 등록 공백 방지.
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

# Container Healthcheck와 별개인 Eureka 등록 상태 확인.
wait_eureka_application "${DEPLOY_ENV}" "FRONTEND"
wait_eureka_application "${DEPLOY_ENV}" "GATEWAY-SERVICE"
wait_eureka_application "${DEPLOY_ENV}" "IDENTITY-SERVICE"
wait_eureka_application "${DEPLOY_ENV}" "LEARNING-SERVICE"

if [[ "${skip_rule}" == "true" ]]; then
  # 부분 배포에서 --remove-orphans 미사용.
  # 기존 단일 Rule 또는 A/B Container의 의도하지 않은 제거 방지.
  echo "SKIP Rule Engine A/B 배포: 기존 Rule Container 상태 유지"
else
  # Compose 정의에서 제거된 이전 단일 rule-service Container 정리.
  # A/B Container의 동시 재생성이 아닌 순차 기동 유지.
  compose up -d --no-deps --remove-orphans discovery-service

  rollout_rule_engine_infra "${DEPLOY_ENV}" || {
    echo "Rule Engine 순차 배포 실패. 일부 인스턴스가 갱신되었을 수 있으므로 A/B 상태와 이미지 태그를 확인하세요." >&2
    exit 1
  }
fi

# 내부 서비스 검증 완료 이후 외부 진입점 반영.
compose up -d --no-deps --wait --wait-timeout 300 nginx cloudflared
if [[ "${skip_rule}" == "true" ]]; then
  "${SMOKE_SCRIPT}" --skip-rule "${base_url}"
  echo "인프라 부분 배포 완료: ${old_sha} -> ${sha} (Rule Engine 제외)"
  exit 0
fi

"${SMOKE_SCRIPT}" "${base_url}"

echo "인프라 배포 완료: ${old_sha} -> ${sha}"
