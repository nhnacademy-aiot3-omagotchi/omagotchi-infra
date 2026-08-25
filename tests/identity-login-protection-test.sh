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

deploy_env="${TEST_TMP_DIR}/deploy.env"
full_secret_env="${TEST_TMP_DIR}/prod.env"
missing_secret_env="${TEST_TMP_DIR}/missing-prod.env"
invalid_deploy_env="${TEST_TMP_DIR}/invalid-deploy.env"

cp "${INFRA_DIR}/deploy.env.example" "${deploy_env}"
cp "${INFRA_DIR}/.env.prod.example" "${full_secret_env}"

for required_setting in LOGIN_MAXIMUM_FAILED_ATTEMPTS LOGIN_LOCK_DURATION; do
  grep -v "^${required_setting}=" "${full_secret_env}" >"${missing_secret_env}"

  if DEPLOY_ENV_FILE="${deploy_env}" SECRET_ENV_FILE="${missing_secret_env}" \
    "${INFRA_DIR}/scripts/compose.sh" config --quiet >/dev/null 2>&1; then
    fail "Identity 로그인 보호 필수 설정 누락이 허용되었습니다: ${required_setting}"
  fi
done

for runtime_setting in LOGIN_MAXIMUM_FAILED_ATTEMPTS LOGIN_LOCK_DURATION; do
  cp "${deploy_env}" "${invalid_deploy_env}"
  grep "^${runtime_setting}=" "${full_secret_env}" >>"${invalid_deploy_env}"

  if DEPLOY_ENV_FILE="${invalid_deploy_env}" SECRET_ENV_FILE="${full_secret_env}" \
    "${INFRA_DIR}/scripts/compose.sh" config --quiet >/dev/null 2>&1; then
    fail "Identity 로그인 보호 설정의 deploy.env 유입이 허용되었습니다: ${runtime_setting}"
  fi
done

if ! DEPLOY_ENV_FILE="${deploy_env}" SECRET_ENV_FILE="${full_secret_env}" \
  "${INFRA_DIR}/scripts/compose.sh" config --format json \
  | jq -e '
      .services["identity-service"].environment.LOGIN_MAXIMUM_FAILED_ATTEMPTS == "5"
      and .services["identity-service"].environment.LOGIN_LOCK_DURATION == "PT10M"
    ' >/dev/null; then
  fail "Identity 로그인 보호 설정이 운영 Compose에 전달되지 않았습니다."
fi

echo "Identity login protection configuration tests passed"
