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
  .services["learning-service-a"].environment.IDENTITY_SERVICE_BASE_URL == "lb://identity-service"
  and .services["rule-engine-a"].environment.LEARNING_BASE_URL == "lb://learning-service"
  and .services["rule-engine-b"].environment.LEARNING_BASE_URL == "lb://learning-service"
  and .services["learning-service-a"].environment.PREDICTION_SERVICE_BASE_URL == "http://nginx:8081"
  and .services["frontend-a"].environment.IDENTITY_SERVICE_BASE_URL == "lb://identity-service"
  and .services["frontend-a"].environment.LEARNING_SERVICE_BASE_URL == "lb://learning-service"
  and .services["frontend-a"].environment.GATEWAY_SERVICE_BASE_URL == "lb://gateway-service"
' "서비스 간 호출 경로 계약이 일치하지 않습니다."

assert_compose_contract '
  def nonempty: type == "string" and length > 0;

  (.services["learning-service-a"].environment.COMMUNITY_ATTACHMENT_BUCKET | nonempty)
  and .services["learning-service-a"].environment.MINIO_BUCKET == null
' "서비스 런타임 설정 연결 계약이 일치하지 않습니다."

assert_compose_contract '
  def nonempty: type == "string" and length > 0;

  (.services["learning-service-a"].environment.LEARNING_IDENTITY_USERNAME | nonempty)
  and (.services["learning-service-a"].environment.LEARNING_IDENTITY_PASSWORD | nonempty)
  and .services["identity-service-a"].environment.LEARNING_IDENTITY_USERNAME
      == .services["learning-service-a"].environment.LEARNING_IDENTITY_USERNAME
  and .services["identity-service-a"].environment.LEARNING_IDENTITY_PASSWORD
      == .services["learning-service-a"].environment.LEARNING_IDENTITY_PASSWORD
  and (.services["learning-service-a"].environment.RULE_LEARNING_USERNAME | nonempty)
  and (.services["learning-service-a"].environment.RULE_LEARNING_PASSWORD | nonempty)
  and .services["rule-engine-a"].environment.RULE_LEARNING_USERNAME
      == .services["learning-service-a"].environment.RULE_LEARNING_USERNAME
  and .services["rule-engine-a"].environment.RULE_LEARNING_PASSWORD
      == .services["learning-service-a"].environment.RULE_LEARNING_PASSWORD
  and .services["rule-engine-b"].environment.RULE_LEARNING_USERNAME
      == .services["learning-service-a"].environment.RULE_LEARNING_USERNAME
  and .services["rule-engine-b"].environment.RULE_LEARNING_PASSWORD
      == .services["learning-service-a"].environment.RULE_LEARNING_PASSWORD
  and (.services["learning-service-a"].environment.LEARNING_PREDICTION_USERNAME | nonempty)
  and (.services["learning-service-a"].environment.LEARNING_PREDICTION_PASSWORD | nonempty)
  and .services["prediction-service-a"].environment.LEARNING_PREDICTION_USERNAME
      == .services["learning-service-a"].environment.LEARNING_PREDICTION_USERNAME
  and .services["prediction-service-a"].environment.LEARNING_PREDICTION_PASSWORD
      == .services["learning-service-a"].environment.LEARNING_PREDICTION_PASSWORD
' "서비스 간 Credential 연결 계약이 일치하지 않습니다."

assert_compose_contract '
  def nonempty: type == "string" and length > 0;
  def has_version_metadata:
    . as $service
    | ($service.environment.SERVICE_VERSION | nonempty)
      and ($service.image | endswith(":" + $service.environment.SERVICE_VERSION))
      and $service.environment.SERVICE_ENVIRONMENT == "prod"
      and ($service.environment.SERVICE_NODE_NAME | nonempty);

  (.services["discovery-service"] | has_version_metadata)
  and (.services["identity-service-a"] | has_version_metadata)
  and (.services["learning-service-a"] | has_version_metadata)
  and (.services["prediction-service-a"] | has_version_metadata)
  and (.services["gateway-service-a"] | has_version_metadata)
  and (.services["rule-engine-a"] | has_version_metadata)
  and (.services["rule-engine-b"] | has_version_metadata)
  and (.services["frontend-a"] | has_version_metadata)
  and .services["rule-engine-a"].environment.SERVICE_NODE_NAME
      == .services["rule-engine-a"].environment.ENGINE_ID
  and .services["rule-engine-b"].environment.SERVICE_NODE_NAME
      == .services["rule-engine-b"].environment.ENGINE_ID
' "구조화 로그의 서비스 식별 Metadata 계약이 일치하지 않습니다."

assert_compose_contract '
  (.services.nginx.tmpfs | index("/var/log/nginx:size=10m,mode=0700")) != null
' "Nginx 상세 오류 로그의 제한 용량 tmpfs가 누락되었습니다."

# 실제 Compose 병합 결과의 A/B 구분과 단일 정의의 기본 실행 제외 확인.
assert_compose_contract '
  .services as $services |
  all(["frontend", "gateway-service", "identity-service", "learning-service", "prediction-service"][];
    . as $name |
    $services[$name] == null
    and $services[$name + "-a"].profiles == ["rollout"]
    and $services[$name + "-b"].profiles == ["rollout"]
    and $services[$name + "-a"].environment.SERVICE_NODE_NAME != $services[$name + "-b"].environment.SERVICE_NODE_NAME
    and $services[$name + "-a"].labels["co.elastic.logs/enabled"] == "true"
    and $services[$name + "-b"].labels["co.elastic.logs/enabled"] == "true")
' "A/B 구분·로그 수집 또는 기존 단일 정의의 기본 실행 제외 오류."

# 슬롯별 상태만 바꾼 경우 반대 자리 이미지와 최종 논리 SHA의 독립성 확인.
printf 'GATEWAY_A_IMAGE_TAG=1111111111111111111111111111111111111111\n' >>"${deploy_env}"
DEPLOY_ENV_FILE="${deploy_env}" SECRET_ENV_FILE="${secret_env}" \
  "${INFRA_DIR}/scripts/compose.sh" config --format json >"${compose_json}"
assert_compose_contract '
  .services["gateway-service-a"].image != .services["gateway-service-b"].image
  and .services["gateway-service-a"].environment.SERVICE_VERSION == "1111111111111111111111111111111111111111"
  and (.services["gateway-service-a"].image | endswith(":" + "1111111111111111111111111111111111111111"))
' "A 슬롯의 이미지 변경이 B 슬롯까지 전파되었습니다."

grep -Ev \
  '^(SENSOR_BROKER_URL|SENSOR_USERNAME|SENSOR_PASSWORD|INTERNAL_SHARED_SECRET)=' \
  "${INFRA_DIR}/.env.prod.example" >"${secret_env}"
grep -Ev '^RULE_IMAGE_TAG=' "${INFRA_DIR}/deploy.env.example" >"${deploy_env}"

if DEPLOY_ENV_FILE="${deploy_env}" SECRET_ENV_FILE="${secret_env}" \
  "${INFRA_DIR}/scripts/compose.sh" config --quiet >/dev/null 2>&1; then
  fail "Rule 필수 설정 없이 전체 Compose 검증이 허용되었습니다."
fi

echo "Compose contract tests passed"
