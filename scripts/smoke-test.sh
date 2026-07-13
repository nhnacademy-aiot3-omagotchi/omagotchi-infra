#!/usr/bin/env bash
set -euo pipefail

# 인자가 없으면 deploy.env의 도메인 사용
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_ENV="$(cd -- "${SCRIPT_DIR}/.." && pwd)/deploy.env"
base_url="${1:-}"

if (( $# > 1 )); then
  echo "사용법: $0 [base-url]" >&2
  exit 64
fi

if [[ -z "${base_url}" && -f "${DEPLOY_ENV}" ]]; then
  base_url="$(awk -F= '$1 == "SMOKE_BASE_URL" { print substr($0, index($0, "=") + 1); exit }' "${DEPLOY_ENV}")"
fi

base_url="${base_url%/}"
if [[ ! "${base_url}" =~ ^https?://[^[:space:]]+$ ]]; then
  echo "Smoke Test base URL이 올바르지 않습니다." >&2
  exit 64
fi

attempts="${SMOKE_ATTEMPTS:-30}"
interval="${SMOKE_INTERVAL_SECONDS:-5}"

# 경로별 필수 응답 내용 확인
matches() {
  local path="$1"
  local body="$2"

  case "${path}" in
    /) [[ "${body}" == *Omagotchi* ]] ;;
    /health) [[ "${body}" == "ok" ]] ;;
    /api/health)
      grep -Eq '"status"[[:space:]]*:[[:space:]]*"UP"' <<<"${body}"
      ;;
    /api/rules/ping)
      grep -Eq '"service"[[:space:]]*:[[:space:]]*"rule-service"' <<<"${body}" &&
        grep -Eq '"status"[[:space:]]*:[[:space:]]*"UP"' <<<"${body}"
      ;;
  esac
}

# HTTP 성공과 응답 내용이 맞을 때까지 재시도
check() {
  local path="$1"
  local body
  local attempt

  for ((attempt = 1; attempt <= attempts; attempt++)); do
    if body="$(
      curl -fsSL \
        --connect-timeout 5 \
        --max-time 15 \
        -H 'Cache-Control: no-cache' \
        "${base_url}${path}" 2>/dev/null
    )" && matches "${path}" "${body}"; then
      echo "PASS GET ${path}"
      return 0
    fi

    if (( attempt < attempts )); then
      echo "WAIT GET ${path} (${attempt}/${attempts})"
      sleep "${interval}"
    fi
  done

  echo "FAIL GET ${path}" >&2
  return 1
}

echo "Smoke Test 시작: ${base_url}"
check "/"
check "/health"
check "/api/health"
check "/api/rules/ping"
echo "Smoke Test 완료"
