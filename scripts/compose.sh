#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

# 평소에는 infra/deploy.env와 ../secrets/prod.env 사용
# 배포 스크립트는 DEPLOY_ENV_FILE만 임시 후보 파일로 바꿔서 사용
DEPLOY_ENV_FILE="${DEPLOY_ENV_FILE:-${INFRA_DIR}/deploy.env}"
SECRET_ENV_FILE="${SECRET_ENV_FILE:-${INFRA_DIR}/../secrets/prod.env}"

if [[ ! -f "${DEPLOY_ENV_FILE}" ]]; then
  echo "배포 상태 파일이 없습니다: ${DEPLOY_ENV_FILE}" >&2
  exit 1
fi

if [[ ! -f "${SECRET_ENV_FILE}" ]]; then
  echo "서버 Secret 파일이 없습니다: ${SECRET_ENV_FILE}" >&2
  exit 1
fi

# deploy.env와 분리할 운영 Runtime 설정
runtime_keys=(
  CLOUDFLARED_TOKEN
  JWT_ISSUER
  JWT_AUDIENCE
  JWT_ACCESS_TOKEN_TTL
  REFRESH_TOKEN_TTL
  IDENTITY_DB_URL
  IDENTITY_DB_USERNAME
  IDENTITY_DB_PASSWORD
  LEARNING_DB_URL
  LEARNING_DB_USERNAME
  LEARNING_DB_PASSWORD
  LEARNING_REDIS_HOST
  LEARNING_REDIS_PORT
  LEARNING_REDIS_USERNAME
  LEARNING_REDIS_PASSWORD
  LEARNING_REDIS_SSL_ENABLED
  TIMER_MAX_DURATION
  TELEGRAM_BOT_USERNAME
  TELEGRAM_LINK_TOKEN_TTL
  COMMUNITY_ATTACHMENT_MAX_FILE_SIZE
  COMMUNITY_ATTACHMENT_MAX_COUNT
  REALTIME_PRESENCE_SESSION_TTL
  SENSOR_BROKER_URL
  SENSOR_CLIENT_ID
  SENSOR_USERNAME
  SENSOR_PASSWORD
  RABBITMQ_HOST
  RABBITMQ_PORT
  RABBITMQ_USERNAME
  RABBITMQ_PASSWORD
  INFLUXDB_URL
  INFLUXDB_TOKEN
  INFLUXDB_ORG_ID
  SESSION_REDIS_HOST
  SESSION_REDIS_PORT
  SESSION_REDIS_USERNAME
  SESSION_REDIS_PASSWORD
  SESSION_REDIS_SSL_ENABLED
  FRONTEND_USERNAME
  FRONTEND_PASSWORD
)

for key in "${runtime_keys[@]}"; do
  if grep -Eq "^[[:space:]]*${key}=" "${DEPLOY_ENV_FILE}"; then
    echo "${key}는 deploy.env가 아니라 prod.env에만 두어야 합니다." >&2
    exit 1
  fi
done

# 이미지 태그는 deploy.env만이 단일 진실 공급원으로
deploy_keys=(
  DISCOVERY_IMAGE_TAG
  GATEWAY_IMAGE_TAG
  IDENTITY_IMAGE_TAG
  LEARNING_IMAGE_TAG
  RULE_IMAGE_TAG
  FRONTEND_IMAGE_TAG
  SMOKE_BASE_URL
)

for key in "${deploy_keys[@]}"; do
  if grep -Eq "^[[:space:]]*${key}=" "${SECRET_ENV_FILE}"; then
    echo "${key}는 prod.env가 아니라 deploy.env에 두어야 합니다." >&2
    exit 1
  fi
done

# 호출한 셸에서 export한 값이 env 파일보다 우선하지 않도록 제거
unset "${runtime_keys[@]}" "${deploy_keys[@]}"

cd "${INFRA_DIR}"

exec docker compose \
  --env-file "${SECRET_ENV_FILE}" \
  --env-file "${DEPLOY_ENV_FILE}" \
  "$@"
