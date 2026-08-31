#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
TEST_TMP_DIR="$(mktemp -d)"
trap 'rm -rf -- "${TEST_TMP_DIR}"' EXIT

fail() {
  echo "$1" >&2
  exit 1
}

secret_env="${TEST_TMP_DIR}/prod.env"
deploy_env="${TEST_TMP_DIR}/deploy.env"

cp "${INFRA_DIR}/.env.prod.example" "${secret_env}"
cp "${INFRA_DIR}/deploy.env.example" "${deploy_env}"

if ! DEPLOY_ENV_FILE="${deploy_env}" \
  SECRET_ENV_FILE="${secret_env}" \
  "${INFRA_DIR}/scripts/compose.sh" config --format json \
  | jq -e '
      .services["identity-service"].environment.EMAIL_VERIFICATION_CODE_TTL == "PT5M"
      and .services["identity-service"].environment.EMAIL_VERIFICATION_COOLDOWN == "PT1M"
      and .services["identity-service"].environment.EMAIL_VERIFICATION_MAXIMUM_FAILED_ATTEMPTS == "5"
      and .services["identity-service"].environment.EMAIL_VERIFICATION_HMAC_SECRET == "replace-with-32-or-more-character-random-secret"
      and .services["identity-service"].environment.RESEND_FROM_EMAIL == "Omagotchi <no-reply@omagotchi.site>"
      and .services["identity-service"].environment.RESEND_CONNECT_TIMEOUT == "PT2S"
      and .services["identity-service"].environment.RESEND_READ_TIMEOUT == "PT5S"
      and .services["learning-service"].environment.INFLUXDB_URL == "https://replace-with-influxdb-host"
      and .services["learning-service"].environment.INFLUXDB_TOKEN == "replace-with-influxdb-token"
      and .services["learning-service"].environment.INFLUXDB_ORG_ID == "replace-with-influxdb-org-id"
      and .services["learning-service"].environment.IDENTITY_SERVICE_BASE_URL == "lb://identity-service"
      and .services["learning-service"].environment.LEARNING_IDENTITY_USERNAME == "learning-service"
      and .services["learning-service"].environment.LEARNING_IDENTITY_PASSWORD == "replace-with-32-to-72-byte-secret"
      and .services["identity-service"].environment.LEARNING_IDENTITY_USERNAME == .services["learning-service"].environment.LEARNING_IDENTITY_USERNAME
      and .services["identity-service"].environment.LEARNING_IDENTITY_PASSWORD == .services["learning-service"].environment.LEARNING_IDENTITY_PASSWORD
      and .services["learning-service"].environment.RULE_LEARNING_USERNAME == "rule-service"
      and .services["learning-service"].environment.RULE_LEARNING_PASSWORD == "replace-with-32-to-72-byte-secret"
      and .services["rule-engine-a"].environment.RULE_LEARNING_USERNAME == .services["learning-service"].environment.RULE_LEARNING_USERNAME
      and .services["rule-engine-a"].environment.RULE_LEARNING_PASSWORD == .services["learning-service"].environment.RULE_LEARNING_PASSWORD
      and .services["rule-engine-a"].environment.LEARNING_BASE_URL == "http://learning-service:8080"
      and .services["rule-engine-a"].environment.CORE_BASE_URL == null
      and .services["rule-engine-b"].environment.RULE_LEARNING_USERNAME == .services["learning-service"].environment.RULE_LEARNING_USERNAME
      and .services["rule-engine-b"].environment.RULE_LEARNING_PASSWORD == .services["learning-service"].environment.RULE_LEARNING_PASSWORD
      and .services["rule-engine-b"].environment.LEARNING_BASE_URL == "http://learning-service:8080"
      and .services["rule-engine-b"].environment.CORE_BASE_URL == null
      and .services["learning-service"].environment.PREDICTION_SERVICE_BASE_URL == "http://prediction-service:8080"
      and .services["learning-service"].environment.LEARNING_PREDICTION_USERNAME == "learning-service"
      and .services["learning-service"].environment.LEARNING_PREDICTION_PASSWORD == "replace-with-32-to-72-byte-secret"
      and .services["prediction-service"].environment.LEARNING_PREDICTION_USERNAME == .services["learning-service"].environment.LEARNING_PREDICTION_USERNAME
      and .services["prediction-service"].environment.LEARNING_PREDICTION_PASSWORD == .services["learning-service"].environment.LEARNING_PREDICTION_PASSWORD
      and .services.frontend.environment.IDENTITY_SERVICE_BASE_URL == "lb://identity-service"
      and .services.frontend.environment.LEARNING_SERVICE_BASE_URL == "lb://learning-service"
      and .services.frontend.environment.GATEWAY_SERVICE_BASE_URL == "lb://gateway-service"
      and .services.frontend.environment.ACCESS_TOKEN_REFRESH_BEFORE_EXPIRY == "30s"
      and .services.frontend.environment.ACCESS_TOKEN_REFRESH_LOCK_WAIT_TIMEOUT == "20s"
      and .services.frontend.environment.ACCESS_TOKEN_REFRESH_LOCK_POLL_INTERVAL == "250ms"
      and .services.frontend.environment.ACCESS_TOKEN_REFRESH_LOCK_LEASE == "45s"
    ' >/dev/null; then
  fail "서비스 설정·Credential 연결 계약이 일치하지 않습니다."
fi

grep -Ev \
  '^(SENSOR_BROKER_URL|SENSOR_USERNAME|SENSOR_PASSWORD|INTERNAL_SHARED_SECRET)=' \
  "${INFRA_DIR}/.env.prod.example" >"${secret_env}"
grep -Ev '^RULE_IMAGE_TAG=' "${INFRA_DIR}/deploy.env.example" >"${deploy_env}"

if DEPLOY_ENV_FILE="${deploy_env}" SECRET_ENV_FILE="${secret_env}" \
  "${INFRA_DIR}/scripts/compose.sh" config --quiet >/dev/null 2>&1; then
  fail "Rule 필수 설정 없이 전체 Compose 검증이 허용되었습니다."
fi

echo "Compose contract tests passed"
