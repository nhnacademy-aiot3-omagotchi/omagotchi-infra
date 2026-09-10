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

read_array_keys() {
  local array_name="$1"

  sed -n "/^${array_name}=(/,/^)/p" "${INFRA_DIR}/scripts/compose.sh" \
    | sed -nE 's/^[[:space:]]+([A-Z][A-Z0-9_]*)$/\1/p'
}

read_env_keys() {
  awk -F= '/^[A-Z][A-Z0-9_]*=/ { print $1 }' "$1"
}

assert_same_keys() {
  local expected_file="$1"
  local actual_file="$2"
  local message="$3"
  local difference

  difference="$(comm -3 "${expected_file}" "${actual_file}")"
  if [[ -n "${difference}" ]]; then
    printf '%s\n%s\n' "${message}" "${difference}" >&2
    exit 1
  fi
}

runtime_keys_file="${TEST_TMP_DIR}/runtime-keys"
observability_keys_file="${TEST_TMP_DIR}/observability-keys"
generated_observability_keys_file="${TEST_TMP_DIR}/generated-observability-keys"
all_runtime_keys_file="${TEST_TMP_DIR}/all-runtime-keys"
deploy_keys_file="${TEST_TMP_DIR}/deploy-keys"
prod_example_keys_file="${TEST_TMP_DIR}/prod-example-keys"
deploy_example_keys_file="${TEST_TMP_DIR}/deploy-example-keys"
compose_keys_file="${TEST_TMP_DIR}/compose-keys"
owned_compose_keys_file="${TEST_TMP_DIR}/owned-compose-keys"

{
  read_array_keys runtime_keys
  read_array_keys optional_runtime_keys
} | LC_ALL=C sort >"${runtime_keys_file}"
# Adapter가 계산하는 설정 해시는 외부에서 등록할 Runtime 값과 구분.
sed -nE 's/^(OBS_[A-Z_]+_CONFIG_REVISION)=.*/\1/p' "${INFRA_DIR}/scripts/observability-compose.sh" \
  | LC_ALL=C sort -u >"${generated_observability_keys_file}"
# $$는 Compose 치환이 아닌 Container Shell의 변수 참조. 외부 Env 소유권에서 제외.
sed 's/\$\$//g' "${INFRA_DIR}/observability/compose.yaml" \
  | grep -oE '\$\{[A-Z][A-Z0-9_]*' \
  | sed 's/^${//' \
  | LC_ALL=C sort -u \
  | comm -23 - "${generated_observability_keys_file}" >"${observability_keys_file}"
cat "${runtime_keys_file}" "${observability_keys_file}" \
  | LC_ALL=C sort -u >"${all_runtime_keys_file}"
read_array_keys deploy_keys | LC_ALL=C sort >"${deploy_keys_file}"
read_env_keys "${INFRA_DIR}/.env.prod.example" | LC_ALL=C sort >"${prod_example_keys_file}"
read_env_keys "${INFRA_DIR}/deploy.env.example" | LC_ALL=C sort >"${deploy_example_keys_file}"

# 앱·관측 설정 예시의 통합, 앱 실행의 필수 설정 범위는 기존대로 유지.
assert_same_keys "${prod_example_keys_file}" "${all_runtime_keys_file}" \
  "prod.env 예시와 앱·관측 Runtime 설정 항목이 일치하지 않습니다."
assert_same_keys "${deploy_example_keys_file}" "${deploy_keys_file}" \
  "deploy.env 예시와 deploy_keys가 일치하지 않습니다."

if comm -12 "${all_runtime_keys_file}" "${deploy_keys_file}" | grep -q .; then
  fail "Runtime 설정과 deploy_keys에 중복 소유 Key가 있습니다."
fi

grep -oE '\$\{[A-Z][A-Z0-9_]*' "${INFRA_DIR}/compose.yaml" \
  | sed 's/^${//' \
  | LC_ALL=C sort -u >"${compose_keys_file}"
{
  cat "${runtime_keys_file}"
  grep -v '^SMOKE_BASE_URL$' "${deploy_keys_file}"
  read_array_keys slot_keys
} | LC_ALL=C sort -u >"${owned_compose_keys_file}"

assert_same_keys "${owned_compose_keys_file}" "${compose_keys_file}" \
  "Compose 환경변수와 환경파일 소유권 목록이 일치하지 않습니다."

if grep -nE '\$\{[A-Z][A-Z0-9_]*(:-|-)' "${INFRA_DIR}/compose.yaml" \
  | grep -vE '\$\{(TRACING_EXPORT_ENABLED|TRACING_SAMPLING_PROBABILITY):-' \
  | grep -vE '\$\{(FRONTEND|GATEWAY|IDENTITY|LEARNING|PREDICTION)_[AB]_IMAGE_TAG:-' \
  >"${TEST_TMP_DIR}/compose-defaults"; then
  cat "${TEST_TMP_DIR}/compose-defaults" >&2
  fail "운영 Compose 환경변수에 암묵적 기본값이 남아 있습니다."
fi

while IFS= read -r expression; do
  # 기존 배포와 호환되는 관측 선택값만 기본값 허용.
  if [[ "${expression}" =~ ^\$\{(TRACING_EXPORT_ENABLED|TRACING_SAMPLING_PROBABILITY):-.*\}$ ]]; then
    continue
  fi
  # 자리별 이미지 기록이 없을 때 논리 SHA 사용. 실제 해석은 Compose 계약 테스트 담당.
  if [[ "${expression}" =~ ^\$\{(FRONTEND|GATEWAY|IDENTITY|LEARNING|PREDICTION)_[AB]_IMAGE_TAG:-\$\{ ]]; then
    continue
  fi
  if [[ ! "${expression}" =~ ^\$\{[A-Z][A-Z0-9_]*(:\?|\?).*\}$ ]]; then
    fail "누락 시 실패하지 않는 Compose 환경변수 표현식이 있습니다: ${expression}"
  fi
done < <(grep -oE '\$\{[^}]+\}' "${INFRA_DIR}/compose.yaml")

deploy_env="${TEST_TMP_DIR}/deploy.env"
full_secret_env="${TEST_TMP_DIR}/prod.env"
candidate_env="${TEST_TMP_DIR}/candidate.env"
cp "${INFRA_DIR}/deploy.env.example" "${deploy_env}"
cp "${INFRA_DIR}/.env.prod.example" "${full_secret_env}"

# 통합 예시와 무관하게 관측 설정 없이 가능한 앱 Compose 실행.
sed -E '/^(ELASTICSEARCH_|OPS_TELEGRAM_|GRAFANA_ADMIN_PASSWORD=|TRACING_)/d' "${full_secret_env}" >"${candidate_env}"
if ! DEPLOY_ENV_FILE="${deploy_env}" SECRET_ENV_FILE="${candidate_env}" \
  "${INFRA_DIR}/scripts/compose.sh" config --quiet; then
  fail "관측 설정 누락으로 앱 Compose 실행이 차단되었습니다."
fi

# 호출 Shell의 값이 선택적 관측 설정의 기본값·운영 파일을 덮어쓰지 않는지 확인.
if ! TRACING_EXPORT_ENABLED=true TRACING_SAMPLING_PROBABILITY=1 \
  DEPLOY_ENV_FILE="${deploy_env}" SECRET_ENV_FILE="${candidate_env}" \
  "${INFRA_DIR}/scripts/compose.sh" config --format json \
  | jq -e '.services["gateway-service-a"].environment
      | .TRACING_EXPORT_ENABLED == "false" and .TRACING_SAMPLING_PROBABILITY == "0.1"' >/dev/null; then
  fail "호출 Shell의 관측 설정이 운영 설정에 혼입되었습니다."
fi

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
