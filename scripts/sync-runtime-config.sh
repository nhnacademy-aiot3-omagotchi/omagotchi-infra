#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

# GitHub Environment에서 전달된 Runtime 설정의 서버 동기화 진입점.
# - 서버 Infra 저장소를 Workflow의 main Revision으로 Fast-forward
# - 후보 prod.env를 현재 deploy.env와 함께 검증
# - 검증 성공 이후에만 직전 설정 백업과 원자적 교체
# - 기본 실행: 설정만 교체, Container·deploy.env 변경 제외
# - --deploy-infra: 잠금을 유지한 채 공용 Infra 반영까지 실행

usage() {
  echo "사용법: $0 <infra-directory> <40-character-commit-sha> <candidate-prod-env> [--deploy-infra]" >&2
}

if (( $# < 3 || $# > 4 )) || [[ "${4:-}" != "" && "${4:-}" != --deploy-infra ]]; then
  usage
  exit 64
fi

INFRA_DIR="$(cd -- "$1" && pwd -P)"
sha="$2"
candidate_argument="$3"
deploy_infra="${4:-}"

if [[ ! "${sha}" =~ ^[0-9a-f]{40}$ ]]; then
  echo "인프라 revision은 소문자 16진수 40자리 commit SHA여야 합니다." >&2
  exit 64
fi

ROOT_DIR="$(cd -- "${INFRA_DIR}/.." && pwd -P)"
SECRETS_DIR="${ROOT_DIR}/secrets"
DEPLOY_ENV="${INFRA_DIR}/deploy.env"
SECRET_ENV="${SECRETS_DIR}/prod.env"
PREVIOUS_SECRET_ENV="${SECRETS_DIR}/prod.env.previous"
COMPOSE_SCRIPT="${INFRA_DIR}/scripts/compose.sh"
LOCK_FILE="${ROOT_DIR}/.omagotchi-deploy.lock"
# 여러 저장소의 연속 배포를 위한 최대 30분 대기. 잠금 획득 후의 실행 시간과 별개.
DEPLOY_LOCK_WAIT_SECONDS=1800

[[ -d "${INFRA_DIR}/.git" ]] || {
  echo "infra Git 저장소가 아닙니다: ${INFRA_DIR}" >&2
  exit 1
}
[[ -d "${SECRETS_DIR}" && ! -L "${SECRETS_DIR}" ]] || {
  echo "secrets 경로가 일반 Directory가 아닙니다: ${SECRETS_DIR}" >&2
  exit 1
}
[[ -f "${DEPLOY_ENV}" && ! -L "${DEPLOY_ENV}" ]] || {
  echo "deploy.env가 일반 파일이 아닙니다." >&2
  exit 1
}
[[ -f "${SECRET_ENV}" && ! -L "${SECRET_ENV}" ]] || {
  echo "현재 prod.env가 일반 파일이 아닙니다." >&2
  exit 1
}
[[ ! -e "${PREVIOUS_SECRET_ENV}" || ( -f "${PREVIOUS_SECRET_ENV}" && ! -L "${PREVIOUS_SECRET_ENV}" ) ]] || {
  echo "prod.env.previous가 일반 파일이 아닙니다." >&2
  exit 1
}

if [[ "${candidate_argument}" != /* ]]; then
  echo "후보 prod.env는 절대 경로여야 합니다." >&2
  exit 64
fi

candidate_directory="$(cd -- "$(dirname -- "${candidate_argument}")" && pwd -P)"
candidate_name="$(basename -- "${candidate_argument}")"

if [[ "${candidate_directory}" != "${SECRETS_DIR}" \
  || ! "${candidate_name}" =~ ^\.incoming-prod\.env\.[A-Za-z0-9._-]+$ ]]; then
  echo "후보 prod.env 경로가 허용된 staging 형식이 아닙니다." >&2
  exit 64
fi

candidate="${candidate_directory}/${candidate_name}"
[[ -f "${candidate}" && ! -L "${candidate}" && -s "${candidate}" ]] || {
  echo "후보 prod.env가 비어 있거나 일반 파일이 아닙니다." >&2
  exit 1
}

previous_candidate=""
compose_validation_output=""
cleanup() {
  [[ -z "${candidate:-}" ]] || rm -f -- "${candidate}"
  [[ -z "${previous_candidate:-}" ]] || rm -f -- "${previous_candidate}"
  [[ -z "${compose_validation_output:-}" ]] || rm -f -- "${compose_validation_output}"
}
trap cleanup EXIT

chmod 600 "${candidate}"

if LC_ALL=C grep -q $'\r' "${candidate}"; then
  echo "후보 prod.env에 CRLF 줄바꿈이 포함되어 있습니다." >&2
  exit 1
fi

duplicate_keys="$({
  awk -F= '
    /^[A-Za-z_][A-Za-z0-9_]*=/ {
      count[$1]++
    }
    END {
      for (key in count) {
        if (count[key] > 1) {
          print key
        }
      }
    }
  ' "${candidate}"
} | LC_ALL=C sort)"

if [[ -n "${duplicate_keys}" ]]; then
  echo "후보 prod.env에 중복 Key가 있습니다:" >&2
  printf '%s\n' "${duplicate_keys}" >&2
  exit 1
fi

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

# 서비스·Infra 배포와 Runtime 설정 교체의 동시 실행 차단.
acquire_deploy_lock \
  "${LOCK_FILE}" \
  "${DEPLOY_LOCK_WAIT_SECONDS}" \
  "Runtime 설정 동기화" || exit 1

cd "${INFRA_DIR}"

if [[ "$(git branch --show-current)" != "main" ]]; then
  echo "서버 infra 저장소가 main 브랜치가 아닙니다." >&2
  exit 1
fi

if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
  echo "서버 infra 저장소에 추적 파일 변경이 있어 설정 동기화를 중단합니다." >&2
  exit 1
fi

old_sha="$(git rev-parse HEAD)"

git fetch \
  --no-tags \
  origin \
  refs/heads/main:refs/remotes/origin/main

git cat-file -e "${sha}^{commit}" 2>/dev/null || {
  echo "동기화할 commit을 찾을 수 없습니다: ${sha}" >&2
  exit 1
}

git merge-base --is-ancestor "${sha}" origin/main || {
  echo "동기화할 commit이 origin/main에 포함되어 있지 않습니다: ${sha}" >&2
  exit 1
}

git merge-base --is-ancestor "${old_sha}" "${sha}" || {
  echo "서버 상태에서 fast-forward할 수 없는 commit입니다: ${old_sha} -> ${sha}" >&2
  exit 1
}

# 공개 Git 파일의 읽기 권한 보존. 이후 Secret 생성에는 기존 umask 077 유지.
(umask 022; git merge --ff-only "${sha}")

[[ -x "${COMPOSE_SCRIPT}" ]] || {
  echo "compose.sh 실행 권한이 없습니다." >&2
  exit 1
}

# 현재 배포 이미지 상태와 후보 Runtime 설정의 완전한 Compose 해석 확인.
compose_validation_output="$(mktemp "${SECRETS_DIR}/.runtime-config-validation.XXXXXX")"
if ! DEPLOY_ENV_FILE="${DEPLOY_ENV}" \
  SECRET_ENV_FILE="${candidate}" \
  "${COMPOSE_SCRIPT}" config --quiet \
  >"${compose_validation_output}" 2>&1; then
  echo "후보 Runtime 설정의 Compose 검증에 실패했습니다. Secret 보호를 위해 상세 출력은 생략합니다." >&2
  exit 1
fi

# 현재 운영 구성의 관측 도구 6개 검증. 과거 단계별 선택 도입 분기 제거.
if ! SECRET_ENV_FILE="${candidate}" \
  "${INFRA_DIR}/scripts/observability-compose.sh" --profile alerts --profile metrics --profile tracing config --format json \
  2>"${compose_validation_output}" \
  | jq -e '[.services.elastalert.environment.OPS_TELEGRAM_BOT_TOKEN,
             .services.elastalert.environment.OPS_TELEGRAM_CHAT_ID,
             .services.grafana.environment.GF_SECURITY_ADMIN_PASSWORD]
           | all(type == "string" and length > 0)' >/dev/null 2>>"${compose_validation_output}"; then
  echo "후보 관측 설정 검증 실패. Elasticsearch·Telegram·Grafana 필수 설정 확인 필요, 기존 설정 유지." >&2
  exit 1
fi
rm -f -- "${compose_validation_output}"
compose_validation_output=""

# 동일한 Runtime 설정의 반복 동기화는 기존 복구본을 덮어쓰지 않음.
if cmp -s -- "${candidate}" "${SECRET_ENV}"; then
  rm -f -- "${candidate}"
  candidate=""
  echo "Runtime 설정 변경 없음: ${old_sha} -> ${sha}"
else
  # 기존 설정의 직전 복구본을 동일 File System에서 원자적으로 확정.
  previous_candidate="$(mktemp "${SECRETS_DIR}/.prod.env.previous.XXXXXX")"
  cp "${SECRET_ENV}" "${previous_candidate}"
  chmod 600 "${previous_candidate}"
  mv -f "${previous_candidate}" "${PREVIOUS_SECRET_ENV}"
  previous_candidate=""

  # 후보 파일은 secrets Directory 내부에 있으므로 동일 File System mv 보장.
  mv -f "${candidate}" "${SECRET_ENV}"
  candidate=""
  chmod 600 "${SECRET_ENV}"

  echo "Runtime 설정 동기화 완료: ${old_sha} -> ${sha}"
fi

# 설정이 같아도 Infra 변경 반영. Git 갱신 전에는 서버의 새 스크립트에 의존하지 않음.
if [[ "${deploy_infra}" == --deploy-infra ]]; then
  # shellcheck disable=SC1091
  source "${INFRA_DIR}/scripts/deploy-infra.sh"
  deploy_infrastructure
fi
