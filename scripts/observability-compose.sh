#!/usr/bin/env bash
set +x
set -euo pipefail

# 관측 설정만 필요한 별도 Compose 진입점. 애플리케이션 설정·이미지 SHA 검증과 분리.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
SECRET_ENV_FILE="${SECRET_ENV_FILE:-${INFRA_DIR}/../secrets/prod.env}"

[[ -f "${SECRET_ENV_FILE}" ]] || {
  echo "서버 Secret 파일이 없습니다: ${SECRET_ENV_FILE}" >&2
  exit 1
}

# 호출 셸의 export 값보다 검토된 prod.env 우선.
unset ELASTICSEARCH_URL ELASTICSEARCH_USERNAME ELASTICSEARCH_PASSWORD
unset OPS_TELEGRAM_BOT_TOKEN OPS_TELEGRAM_CHAT_ID
# 이전 셸의 Profile 설정에 따른 초기화 Service의 우발적 기동 방지.
unset COMPOSE_PROFILES

exec docker compose \
  --project-name omagotchi-observability \
  --env-file "${SECRET_ENV_FILE}" \
  --file "${INFRA_DIR}/observability/compose.yaml" \
  "$@"
