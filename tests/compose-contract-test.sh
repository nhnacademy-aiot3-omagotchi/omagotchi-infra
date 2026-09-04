#!/usr/bin/env bash
# shellcheck disable=SC2016 # jq 식은 Shell 확장 없이 그대로 전달
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
compose_json="${TEST_TMP_DIR}/compose.json"

cp "${INFRA_DIR}/.env.prod.example" "${secret_env}"
cp "${INFRA_DIR}/deploy.env.example" "${deploy_env}"

assert_compose_contract() {
  local expression="$1"
  local message="$2"

  jq -e "${expression}" "${compose_json}" >/dev/null || fail "${message}"
}

if ! DEPLOY_ENV_FILE="${deploy_env}" \
  SECRET_ENV_FILE="${secret_env}" \
  "${INFRA_DIR}/scripts/compose.sh" config --format json >"${compose_json}"; then
  fail "예시 환경설정으로 Compose 구성을 해석할 수 없습니다."
fi

assert_compose_contract '
  .services["learning-service"].environment.IDENTITY_SERVICE_BASE_URL == "lb://identity-service"
  and .services["rule-engine-a"].environment.LEARNING_BASE_URL == "http://learning-service:8080"
  and .services["rule-engine-b"].environment.LEARNING_BASE_URL == "http://learning-service:8080"
  and .services["learning-service"].environment.PREDICTION_SERVICE_BASE_URL == "http://prediction-service:8080"
  and .services.frontend.environment.IDENTITY_SERVICE_BASE_URL == "lb://identity-service"
  and .services.frontend.environment.LEARNING_SERVICE_BASE_URL == "lb://learning-service"
  and .services.frontend.environment.GATEWAY_SERVICE_BASE_URL == "lb://gateway-service"
' "서비스 간 호출 경로 계약이 일치하지 않습니다."

assert_compose_contract '
  def nonempty: type == "string" and length > 0;

  (.services["learning-service"].environment.COMMUNITY_ATTACHMENT_MAX_FILE_SIZE | nonempty)
  and (.services["learning-service"].environment.COMMUNITY_ATTACHMENT_MAX_REQUEST_SIZE | nonempty)
  and (.services["learning-service"].environment.COMMUNITY_ATTACHMENT_MAX_COUNT | nonempty)
  and (.services["learning-service"].environment.COMMUNITY_ATTACHMENT_BUCKET | nonempty)
  and .services["learning-service"].environment.MINIO_BUCKET == null
  and (.services.frontend.environment.AI_CHAT_READ_TIMEOUT | nonempty)
' "서비스 런타임 설정 연결 계약이 일치하지 않습니다."

assert_compose_contract '
  def nonempty: type == "string" and length > 0;

  (.services["learning-service"].environment.LEARNING_IDENTITY_USERNAME | nonempty)
  and (.services["learning-service"].environment.LEARNING_IDENTITY_PASSWORD | nonempty)
  and .services["identity-service"].environment.LEARNING_IDENTITY_USERNAME
      == .services["learning-service"].environment.LEARNING_IDENTITY_USERNAME
  and .services["identity-service"].environment.LEARNING_IDENTITY_PASSWORD
      == .services["learning-service"].environment.LEARNING_IDENTITY_PASSWORD
  and (.services["learning-service"].environment.RULE_LEARNING_USERNAME | nonempty)
  and (.services["learning-service"].environment.RULE_LEARNING_PASSWORD | nonempty)
  and .services["rule-engine-a"].environment.RULE_LEARNING_USERNAME
      == .services["learning-service"].environment.RULE_LEARNING_USERNAME
  and .services["rule-engine-a"].environment.RULE_LEARNING_PASSWORD
      == .services["learning-service"].environment.RULE_LEARNING_PASSWORD
  and .services["rule-engine-b"].environment.RULE_LEARNING_USERNAME
      == .services["learning-service"].environment.RULE_LEARNING_USERNAME
  and .services["rule-engine-b"].environment.RULE_LEARNING_PASSWORD
      == .services["learning-service"].environment.RULE_LEARNING_PASSWORD
  and (.services["learning-service"].environment.LEARNING_PREDICTION_USERNAME | nonempty)
  and (.services["learning-service"].environment.LEARNING_PREDICTION_PASSWORD | nonempty)
  and .services["prediction-service"].environment.LEARNING_PREDICTION_USERNAME
      == .services["learning-service"].environment.LEARNING_PREDICTION_USERNAME
  and .services["prediction-service"].environment.LEARNING_PREDICTION_PASSWORD
      == .services["learning-service"].environment.LEARNING_PREDICTION_PASSWORD
' "서비스 간 Credential 연결 계약이 일치하지 않습니다."

assert_compose_contract '
  def nonempty: type == "string" and length > 0;
  def has_version_metadata:
    . as $service
    | ($service.environment.SERVICE_VERSION | nonempty)
      and ($service.image | endswith(":" + $service.environment.SERVICE_VERSION))
      and $service.environment.SERVICE_ENVIRONMENT == "prod"
      and ($service.environment.SERVICE_NODE_NAME | nonempty);

  (.services["gateway-service"] | has_version_metadata)
  and (.services["rule-engine-a"] | has_version_metadata)
  and (.services["rule-engine-b"] | has_version_metadata)
  and .services["rule-engine-a"].environment.SERVICE_NODE_NAME
      == .services["rule-engine-a"].environment.ENGINE_ID
  and .services["rule-engine-b"].environment.SERVICE_NODE_NAME
      == .services["rule-engine-b"].environment.ENGINE_ID
' "구조화 로그의 서비스 식별 Metadata 계약이 일치하지 않습니다."

assert_compose_contract '
  (.services.nginx.tmpfs | index("/var/log/nginx:size=10m,mode=0700")) != null
' "Nginx 상세 오류 로그의 제한 용량 tmpfs가 누락되었습니다."

grep -Ev \
  '^(SENSOR_BROKER_URL|SENSOR_USERNAME|SENSOR_PASSWORD|INTERNAL_SHARED_SECRET)=' \
  "${INFRA_DIR}/.env.prod.example" >"${secret_env}"
grep -Ev '^RULE_IMAGE_TAG=' "${INFRA_DIR}/deploy.env.example" >"${deploy_env}"

if DEPLOY_ENV_FILE="${deploy_env}" SECRET_ENV_FILE="${secret_env}" \
  "${INFRA_DIR}/scripts/compose.sh" config --quiet >/dev/null 2>&1; then
  fail "Rule 필수 설정 없이 전체 Compose 검증이 허용되었습니다."
fi

echo "Compose contract tests passed"
