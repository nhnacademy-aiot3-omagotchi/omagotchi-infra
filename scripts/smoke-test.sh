#!/usr/bin/env bash
set -euo pipefail

# 외부 사용자 경로 기준의 배포 완료 검증.
# Container 내부 Healthcheck와 구분되는 Cloudflare·Nginx·Gateway 포함 확인.
# 검증 범위: 공개 화면, 서비스 상태, Rule 라우팅, 인증 경계, 내부 API 미노출.

# 인자 미지정 시 deploy.env의 운영 주소 사용.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_ENV="$(cd -- "${SCRIPT_DIR}/.." && pwd)/deploy.env"
base_url=""
attempts=""
interval=""

# HTTP 2xx만으로 부족한 공개·상태 경로의 최소 응답 계약 확인.
matches() {
  local path="$1"
  local body="$2"

  case "${path}" in
    /) [[ "${body}" == *Omagotchi* ]] ;;
    /health) [[ "${body}" == "ok" ]] ;;
    /api/health)
      grep -Eq '"status"[[:space:]]*:[[:space:]]*"UP"' <<<"${body}"
      ;;
    /api/v1/rules/ping)
      grep -Eq '"service"[[:space:]]*:[[:space:]]*"rule-service"' <<<"${body}" &&
        grep -Eq '"status"[[:space:]]*:[[:space:]]*"UP"' <<<"${body}"
      ;;
  esac
}

# 배포 직후 Registry·Proxy 전파 지연을 고려한 내용 기반 재시도.
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

# 상태 코드 기반 보안 경계 확인.
# 404: Gateway 미라우팅, 401: 공개 경로로 잘못 노출되지 않은 보호 API.
check_status() {
  local path="$1"
  local expected_status="$2"
  local actual_status
  local attempt

  for ((attempt = 1; attempt <= attempts; attempt++)); do
    if actual_status="$(
      curl -sSL \
        --connect-timeout 5 \
        --max-time 15 \
        --output /dev/null \
        --write-out '%{http_code}' \
        -H 'Cache-Control: no-cache' \
        "${base_url}${path}" 2>/dev/null
    )" && [[ "${actual_status}" == "${expected_status}" ]]; then
      echo "PASS GET ${path} (${expected_status})"
      return 0
    fi

    if (( attempt < attempts )); then
      echo "WAIT GET ${path} (${actual_status:-connection-error}, ${attempt}/${attempts})"
      sleep "${interval}"
    fi
  done

  echo "FAIL GET ${path}: expected ${expected_status}, got ${actual_status:-connection-error}" >&2
  return 1
}

smoke_test_main() {
  local skip_rule=false

  if [[ "${1:-}" == "--skip-rule" ]]; then
    skip_rule=true
    shift
  fi

  if (( $# > 1 )); then
    echo "사용법: $0 [--skip-rule] [base-url]" >&2
    exit 64
  fi

  base_url="${1:-}"
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

  # 위에서 아래로 진행하는 Fail-fast 검증.
  # 하나의 경로라도 최종 실패 시 후속 deploy.env 확정 차단.
  echo "Smoke Test 시작: ${base_url}"
  check "/"
  check "/health"
  check "/api/health"

  if [[ "${skip_rule}" == "true" ]]; then
    echo "SKIP GET /api/v1/rules/ping (Rule Engine 제외 배포)"
  else
    check "/api/v1/rules/ping"
  fi

  # Rule 미기동 여부와 무관하게 내부 API의 외부 미라우팅 계약 유지.
  check_status "/api/v1/internal/engines/self" "404"
  check_status "/api/v1/users/me" "401"
  check_status "/api/v1/cohorts" "401"
  check_status "/api/v1/rules" "401"
  echo "Smoke Test 완료"
}

# 테스트 source 시 main 미실행, 직접 실행 시에만 실제 검증 시작.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  smoke_test_main "$@"
fi
