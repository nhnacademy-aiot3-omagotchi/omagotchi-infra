#!/usr/bin/env bash
set -euo pipefail

# Docker Compose 공통 실행 진입점.
# - prod.env: Runtime 설정과 Secret의 공급원
# - deploy.env: 이미지 SHA와 Smoke Test 주소의 공급원
# - 호출 셸의 export 값: 두 파일의 값을 덮어쓰지 못하도록 제거 대상

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

# 기본 파일: infra/deploy.env와 ../secrets/prod.env.
# 서비스 배포 중 후보 이미지 검증: DEPLOY_ENV_FILE만 임시 파일로 교체.
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

# prod.env 전용 항목.
# deploy.env 유입 시 Secret과 배포 상태의 책임 혼합으로 간주.
runtime_keys=(
  CLOUDFLARED_TOKEN
  JWT_ISSUER
  JWT_AUDIENCE
  JWT_ACCESS_TOKEN_TTL
  REFRESH_TOKEN_TTL
  IDENTITY_DB_URL
  IDENTITY_DB_USERNAME
  IDENTITY_DB_PASSWORD
  IDENTITY_REDIS_HOST
  IDENTITY_REDIS_PORT
  IDENTITY_REDIS_DATABASE
  IDENTITY_REDIS_USERNAME
  IDENTITY_REDIS_PASSWORD
  IDENTITY_REDIS_SSL_ENABLED
  RESEND_API_KEY
  RESEND_FROM_EMAIL
  LOGIN_MAXIMUM_FAILED_ATTEMPTS
  LOGIN_LOCK_DURATION
  LEARNING_DB_URL
  LEARNING_DB_USERNAME
  LEARNING_DB_PASSWORD
  LEARNING_REDIS_HOST
  LEARNING_REDIS_PORT
  LEARNING_REDIS_DATABASE
  LEARNING_REDIS_USERNAME
  LEARNING_REDIS_PASSWORD
  LEARNING_REDIS_SSL_ENABLED
  TIMER_MAX_DURATION
  TELEGRAM_BOT_USERNAME
  TELEGRAM_BOT_TOKEN
  TELEGRAM_LINK_TOKEN_TTL
  COMMUNITY_ATTACHMENT_MAX_FILE_SIZE
  COMMUNITY_ATTACHMENT_MAX_COUNT
  REALTIME_PRESENCE_SESSION_TTL
  SENSOR_BROKER_URL
  SENSOR_USERNAME
  SENSOR_PASSWORD
  INTERNAL_SHARED_SECRET
  RABBITMQ_HOST
  RABBITMQ_PORT
  RABBITMQ_USERNAME
  RABBITMQ_PASSWORD
  INFLUXDB_URL
  INFLUXDB_TOKEN
  INFLUXDB_ORG_ID
  SESSION_REDIS_HOST
  SESSION_REDIS_PORT
  SESSION_REDIS_DATABASE
  SESSION_REDIS_USERNAME
  SESSION_REDIS_PASSWORD
  SESSION_REDIS_SSL_ENABLED
  FRONTEND_USERNAME
  FRONTEND_PASSWORD
  LEARNING_IDENTITY_USERNAME
  LEARNING_IDENTITY_PASSWORD
  RULE_LEARNING_USERNAME
  RULE_LEARNING_PASSWORD
  LEARNING_PREDICTION_USERNAME
  LEARNING_PREDICTION_PASSWORD
)

for key in "${runtime_keys[@]}"; do
  if ! grep -Eq "^[[:space:]]*${key}=" "${SECRET_ENV_FILE}"; then
    echo "prod.env에 필수 Runtime 설정이 없습니다: ${key}" >&2
    exit 1
  fi

  if grep -Eq "^[[:space:]]*${key}=" "${DEPLOY_ENV_FILE}"; then
    echo "${key}는 deploy.env가 아니라 prod.env에만 두어야 합니다." >&2
    exit 1
  fi
done

# deploy.env 전용 항목.
# prod.env 유입 시 현재 실행 이미지의 추적 불가 상태로 간주.
deploy_keys=(
  DISCOVERY_IMAGE_TAG
  GATEWAY_IMAGE_TAG
  IDENTITY_IMAGE_TAG
  LEARNING_IMAGE_TAG
  RULE_IMAGE_TAG
  FRONTEND_IMAGE_TAG
  PREDICTION_IMAGE_TAG
  SMOKE_BASE_URL
)

for key in "${deploy_keys[@]}"; do
  if ! grep -Eq "^[[:space:]]*${key}=" "${DEPLOY_ENV_FILE}"; then
    echo "deploy.env에 필수 배포 상태가 없습니다: ${key}" >&2
    exit 1
  fi

  if grep -Eq "^[[:space:]]*${key}=" "${SECRET_ENV_FILE}"; then
    echo "${key}는 prod.env가 아니라 deploy.env에 두어야 합니다." >&2
    exit 1
  fi
done

# Compose 환경변수 우선순위에 따른 호출 셸 export 값의 혼입 차단.
unset "${runtime_keys[@]}" "${deploy_keys[@]}"

cd "${INFRA_DIR}"

# 검증을 통과한 두 파일만 사용하는 실제 Compose 실행.
# exec 사용 목적: Wrapper Process를 남기지 않는 신호·종료 코드 전달.
exec docker compose \
  --env-file "${SECRET_ENV_FILE}" \
  --env-file "${DEPLOY_ENV_FILE}" \
  "$@"
