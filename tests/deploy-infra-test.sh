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

assert_contains() {
  local pattern="$1"
  local file="$2"
  local message="$3"

  grep -Fq -- "${pattern}" "${file}" || fail "${message}"
}

assert_not_contains() {
  local pattern="$1"
  local file="$2"
  local message="$3"

  if grep -Fq -- "${pattern}" "${file}"; then
    fail "${message}"
  fi
}

assert_before() {
  local first_pattern="$1"
  local second_pattern="$2"
  local file="$3"
  local message="$4"
  local first_line
  local second_line

  first_line="$(grep -Fn -- "${first_pattern}" "${file}" | head -n 1 | cut -d: -f1)"
  second_line="$(grep -Fn -- "${second_pattern}" "${file}" | head -n 1 | cut -d: -f1)"
  [[ -n "${first_line}" && -n "${second_line}" && "${first_line}" -lt "${second_line}" ]] ||
    fail "${message}"
}

fixture_dir="${TEST_TMP_DIR}/omagotchi/infra"
events_file="${TEST_TMP_DIR}/events"
output_file="${TEST_TMP_DIR}/output"

mkdir -p \
  "${fixture_dir}/scripts" \
  "${fixture_dir}/../secrets"
printf 'SMOKE_BASE_URL=https://example.invalid\n' >"${fixture_dir}/deploy.env"
touch "${fixture_dir}/../secrets/prod.env"
chmod 600 "${fixture_dir}/../secrets/prod.env" "${fixture_dir}/deploy.env"

# 이전 umask 077 배포의 공개 파일 권한 재현.
cp -R "${INFRA_DIR}/observability" "${fixture_dir}/observability"
cp "${INFRA_DIR}/scripts/observability-setup.sh" "${fixture_dir}/scripts/"
chmod -R u=rwX,go= "${fixture_dir}/observability"
chmod 700 "${fixture_dir}/scripts/observability-setup.sh"

cat >"${fixture_dir}/scripts/compose.sh" <<'EOF'
#!/usr/bin/env bash
printf 'compose:%s\n' "$*" >>"${MODE_TEST_EVENTS}"
# Compose exec의 기본 stdin 연결 재현. -T만 사용하면 남은 배포 Script 소비.
if [[ "$1" == "exec" && " $* " != *" --interactive=false "* ]]; then
  cat >/dev/null
fi
if [[ "${MODE_TEST_FAIL_NGINX_RELOAD:-false}" == "true"
  && "$*" == *"nginx nginx -s reload" ]]; then
  exit 1
fi
EOF

cat >"${fixture_dir}/scripts/smoke-test.sh" <<'EOF'
#!/usr/bin/env bash
printf 'smoke:%s\n' "$*" >>"${MODE_TEST_EVENTS}"
EOF

cat >"${fixture_dir}/scripts/deploy-observability.sh" <<'EOF'
#!/usr/bin/env bash
printf 'observability:%s\n' "${SECRET_ENV_FILE}" >>"${MODE_TEST_EVENTS}"
[[ "${MODE_TEST_FAIL_OBSERVABILITY:-false}" != true ]]
EOF

# Infra에서는 분배 목록 준비만 허용, 앱 교체 호출 시 실패.
cat >"${fixture_dir}/scripts/rolling-deploy.sh" <<'EOF'
rolling_compose() { shift; "${COMPOSE_SCRIPT}" "$@"; }
rolling_initialize_routes() { printf 'routes:initialize\n' >>"${MODE_TEST_EVENTS}"; }
rolling_deploy() { echo "Infra에서 앱 교체 호출" >&2; return 1; }
EOF

chmod +x \
  "${fixture_dir}/scripts/compose.sh" \
  "${fixture_dir}/scripts/smoke-test.sh"

if bash "${INFRA_DIR}/scripts/deploy-infra.sh" >/dev/null 2>&1; then
  fail "잠금 없는 Infra 반영 함수의 단독 실행이 허용되었습니다."
fi

# 실제 반영 함수 실행. 잠금·Git·후보 설정 검증은 runtime-config-sync-test.sh 담당.
# shellcheck disable=SC2034,SC1091 # 동적 경로로 로드한 배포 함수에 전달하는 경로.
run_deployment() (
  set -Eeuo pipefail
  INFRA_DIR="${fixture_dir}"
  DEPLOY_ENV="${fixture_dir}/deploy.env"
  SECRET_ENV="${fixture_dir%/infra}/secrets/prod.env"
  COMPOSE_SCRIPT="${fixture_dir}/scripts/compose.sh"
  export MODE_TEST_EVENTS="${events_file}"
  cd "${fixture_dir}"
  # shellcheck disable=SC1090
  source "${SCRIPT_DIR}/../scripts/deploy-infra.sh"
  deploy_infrastructure
)
: >"${events_file}"
run_deployment >"${output_file}"

# 앱 종류·설정 변경과 무관하게 Nginx·Cloudflared만 기동.
assert_contains 'compose:up -d --no-deps --wait --wait-timeout 300 nginx cloudflared' "${events_file}" "공용 진입점 반영 누락."
[[ "$(grep -c '^compose:up ' "${events_file}")" == 1 ]] || fail "Infra 배포에서 앱 또는 Discovery 교체."
assert_contains "smoke:https://example.invalid" "${events_file}" \
  "전체 배포 Smoke Test가 누락되었습니다."
assert_before "nginx nginx -t" \
  "nginx nginx -s reload" "${events_file}" \
  "Nginx 설정 검증이 reload보다 먼저 실행되지 않았습니다."
assert_before "nginx nginx -s reload" \
  "smoke:https://example.invalid" "${events_file}" \
  "Nginx reload가 Smoke Test보다 먼저 실행되지 않았습니다."
assert_before "smoke:https://example.invalid" \
  "observability:${fixture_dir%/infra}/secrets/prod.env" "${events_file}" \
  "업무 서비스 검증 이후의 관측성 배포 또는 Runtime 설정 전달 누락."
assert_contains "인프라 배포 완료" "${output_file}" \
  "전체 배포 완료 상태가 명시되지 않았습니다."

# 기존 관측 파일의 읽기·디렉터리 탐색 권한 복구 확인.
for public_file in \
  "${fixture_dir}/observability/filebeat/filebeat.yml" \
  "${fixture_dir}/observability/elastalert2/runtime.py"; do
  mode="$(stat -c '%a' "${public_file}" 2>/dev/null || stat -f '%Lp' "${public_file}")"
  [[ "${mode}" == 644 ]] || fail "공개 파일의 읽기 권한 복구 실패: ${public_file}"
done
for public_directory in \
  "${fixture_dir}/observability/elasticsearch" \
  "${fixture_dir}/observability/elastalert2/rules"; do
  mode="$(stat -c '%a' "${public_directory}" 2>/dev/null || stat -f '%Lp' "${public_directory}")"
  [[ "${mode}" == 755 ]] || fail "공개 디렉터리의 탐색 권한 복구 실패: ${public_directory}"
done
setup_script="${fixture_dir}/scripts/observability-setup.sh"
mode="$(stat -c '%a' "${setup_script}" 2>/dev/null || stat -f '%Lp' "${setup_script}")"
[[ "${mode}" == 755 ]] || fail "관측 초기화 Script의 읽기·실행 권한 복구 실패: ${setup_script}"

for private_file in "${fixture_dir}/../secrets/prod.env" "${fixture_dir}/deploy.env"; do
  mode="$(stat -c '%a' "${private_file}" 2>/dev/null || stat -f '%Lp' "${private_file}")"
  [[ "${mode}" == 600 ]] || fail "비공개 파일의 권한 변경: ${private_file}"
done

: >"${events_file}"
if MODE_TEST_FAIL_NGINX_RELOAD=true run_deployment >/dev/null 2>&1; then
  fail "Nginx reload 실패가 전체 배포 실패로 전파되지 않았습니다."
fi
assert_not_contains "smoke:" "${events_file}" \
  "Nginx reload 실패 이후 Smoke Test가 실행되었습니다."

# 관측성 실패 이후 전체 배포의 성공 처리·업무 재배포 방지.
: >"${events_file}"
if MODE_TEST_FAIL_OBSERVABILITY=true run_deployment >"${output_file}" 2>&1; then
  fail "관측성 실패가 전체 배포 실패로 전파되지 않았습니다."
fi
assert_not_contains "인프라 배포 완료" "${output_file}" \
  "관측성 실패 이후 전체 배포의 성공 처리."
[[ "$(tail -n 1 "${events_file}")" == observability:* ]] ||
  fail "관측성 실패 이후 업무 서비스 변경."

echo "Deploy infra tests passed"
