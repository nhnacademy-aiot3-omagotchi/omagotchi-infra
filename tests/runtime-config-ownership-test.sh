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
candidate_env="${TEST_TMP_DIR}/candidate.env"
cp "${INFRA_DIR}/deploy.env.example" "${deploy_env}"
cp "${INFRA_DIR}/.env.prod.example" "${full_secret_env}"

# 관측 설정 없이 가능한 앱 실행과 기본 설정 보관.
sed -E '/^(ELASTICSEARCH_|OPS_TELEGRAM_|GRAFANA_ADMIN_PASSWORD=|TRACING_)/d' "${full_secret_env}" >"${candidate_env}"
if ! baseline="$(DEPLOY_ENV_FILE="${deploy_env}" SECRET_ENV_FILE="${candidate_env}" \
  "${INFRA_DIR}/scripts/compose.sh" config --format json \
  | jq -cS '.services["gateway-service-a"].environment')"; then
  fail "관측 설정 누락으로 앱 Compose 실행이 차단되었습니다."
fi

# 기본값 자체를 고정하지 않고 호출 셸의 값에 따른 결과 변화만 확인.
actual="$(TRACING_EXPORT_ENABLED=true TRACING_SAMPLING_PROBABILITY=1 \
  DEPLOY_ENV_FILE="${deploy_env}" SECRET_ENV_FILE="${candidate_env}" \
  "${INFRA_DIR}/scripts/compose.sh" config --format json \
  | jq -cS '.services["gateway-service-a"].environment')"
[[ "${actual}" == "${baseline}" ]] || fail "호출 셸의 관측 설정이 기본값을 덮어썼습니다."

# 파일에 명시한 설정의 우선 적용. 운영 기본값과 구분되는 테스트용 값 사용.
printf 'TRACING_EXPORT_ENABLED=true\nTRACING_SAMPLING_PROBABILITY=0.25\n' >>"${candidate_env}"
TRACING_EXPORT_ENABLED=false TRACING_SAMPLING_PROBABILITY=1 \
  DEPLOY_ENV_FILE="${deploy_env}" SECRET_ENV_FILE="${candidate_env}" \
  "${INFRA_DIR}/scripts/compose.sh" config --format json \
  | jq -e '.services["gateway-service-a"].environment
      | .TRACING_EXPORT_ENABLED == "true" and .TRACING_SAMPLING_PROBABILITY == "0.25"' >/dev/null \
  || fail "호출 셸의 값이 파일의 관측 설정을 덮어썼습니다."

# Runtime 설정과 배포 상태의 누락·책임 혼합 차단.
grep -v '^JWT_ACCESS_TOKEN_TTL=' "${full_secret_env}" >"${candidate_env}"
if DEPLOY_ENV_FILE="${deploy_env}" SECRET_ENV_FILE="${candidate_env}" \
  "${INFRA_DIR}/scripts/compose.sh" config --quiet >/dev/null 2>&1; then
  fail "Runtime 설정 누락이 허용되었습니다."
fi

cp "${deploy_env}" "${candidate_env}"
printf 'JWT_ACCESS_TOKEN_TTL=misplaced-runtime-value\n' >>"${candidate_env}"
if DEPLOY_ENV_FILE="${candidate_env}" SECRET_ENV_FILE="${full_secret_env}" \
  "${INFRA_DIR}/scripts/compose.sh" config --quiet >/dev/null 2>&1; then
  fail "Runtime 설정의 deploy.env 유입이 허용되었습니다."
fi

grep -v '^SMOKE_BASE_URL=' "${deploy_env}" >"${candidate_env}"
if DEPLOY_ENV_FILE="${candidate_env}" SECRET_ENV_FILE="${full_secret_env}" \
  "${INFRA_DIR}/scripts/compose.sh" config --quiet >/dev/null 2>&1; then
  fail "배포 상태 누락이 허용되었습니다."
fi

cp "${full_secret_env}" "${candidate_env}"
printf 'SMOKE_BASE_URL=https://misplaced.invalid\n' >>"${candidate_env}"
if DEPLOY_ENV_FILE="${deploy_env}" SECRET_ENV_FILE="${candidate_env}" \
  "${INFRA_DIR}/scripts/compose.sh" config --quiet >/dev/null 2>&1; then
  fail "배포 상태의 prod.env 유입이 허용되었습니다."
fi

# 빈 값을 허용하지 않는 필수 설정의 Fail-fast 검증.
sed -E 's/^(JWT_ACCESS_TOKEN_TTL)=.*/\1=/' "${full_secret_env}" >"${candidate_env}"
if DEPLOY_ENV_FILE="${deploy_env}" SECRET_ENV_FILE="${candidate_env}" \
  "${INFRA_DIR}/scripts/compose.sh" config --quiet >/dev/null 2>&1; then
  fail "빈 필수 Runtime 설정이 허용되었습니다."
fi

# 선택적 Credential의 빈 값 허용과 Key 자체의 필수 존재를 분리.
sed -E \
  -e 's/^(IDENTITY_REDIS_USERNAME)=.*/\1=/' \
  -e 's/^(LEARNING_REDIS_USERNAME)=.*/\1=/' \
  -e 's/^(SENSOR_USERNAME)=.*/\1=/' \
  -e 's/^(SENSOR_PASSWORD)=.*/\1=/' \
  -e 's/^(SESSION_REDIS_USERNAME)=.*/\1=/' \
  "${full_secret_env}" >"${candidate_env}"

if ! DEPLOY_ENV_FILE="${deploy_env}" SECRET_ENV_FILE="${candidate_env}" \
  "${INFRA_DIR}/scripts/compose.sh" config --quiet; then
  fail "명시적으로 빈 선택적 Credential이 거부되었습니다."
fi

# 이전 prod.env에 남은 정책값의 Container 재주입 방지.
cp "${full_secret_env}" "${candidate_env}"
printf 'LOGIN_MAXIMUM_FAILED_ATTEMPTS=9\nLOGIN_LOCK_DURATION=PT20M\nSESSION_TIMEOUT=PT30M\n' >>"${candidate_env}"
if ! DEPLOY_ENV_FILE="${deploy_env}" SECRET_ENV_FILE="${candidate_env}" \
  "${INFRA_DIR}/scripts/compose.sh" config --format json \
  | jq -e '
      .services["identity-service-a"].environment.LOGIN_MAXIMUM_FAILED_ATTEMPTS == null
      and .services["identity-service-a"].environment.LOGIN_LOCK_DURATION == null
      and .services["frontend-a"].environment.SESSION_TIMEOUT == null
    ' >/dev/null; then
  fail "서비스로 이관한 정책값이 이전 prod.env에서 다시 주입되었습니다."
fi

echo "Runtime configuration ownership tests passed"
