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

"${COMPOSE_SCRIPT}" config --quiet
"${COMPOSE_SCRIPT}" up -d --wait --wait-timeout 300
"${SMOKE_SCRIPT}"

echo "인프라 배포 완료: ${old_sha} -> ${sha}"
