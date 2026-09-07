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
fake_bin="${TEST_TMP_DIR}/bin"
sha="1111111111111111111111111111111111111111"

mkdir -p \
  "${fixture_dir}/.git" \
  "${fixture_dir}/scripts" \
  "${fixture_dir}/../secrets" \
  "${fake_bin}"
printf 'SMOKE_BASE_URL=https://example.invalid\n' >"${fixture_dir}/deploy.env"
touch "${fixture_dir}/../secrets/prod.env"
chmod 600 "${fixture_dir}/../secrets/prod.env" "${fixture_dir}/deploy.env"

# 이전 umask 077 배포의 공개 파일 권한 재현.
cp -R "${INFRA_DIR}/observability" "${fixture_dir}/observability"
cp "${INFRA_DIR}/scripts/observability-setup.sh" "${fixture_dir}/scripts/"
chmod -R u=rwX,go= "${fixture_dir}/observability"
chmod 700 "${fixture_dir}/scripts/observability-setup.sh"

cat >"${fake_bin}/git" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  branch) printf 'main\n' ;;
  status) ;;
  rev-parse) printf '0000000000000000000000000000000000000000\n' ;;
  fetch | cat-file | merge-base) ;;
  merge) mkdir -p checkout-fixture; touch checkout-fixture/public.conf ;;
  *) exit 1 ;;
esac
EOF

cat >"${fake_bin}/flock" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

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

cat >"${fixture_dir}/scripts/rule-engine.sh" <<'EOF'
# 실제 Eureka 확인 함수 사용, Rule Container 변경만 대역 처리.
# shellcheck disable=SC1090
source "${MODE_TEST_RULE_ENGINE}"

rollout_rule_engine_infra() {
  printf 'rule-rollout:%s\n' "$1" >>"${MODE_TEST_EVENTS}"
}
EOF

chmod +x \
  "${fake_bin}/flock" \
  "${fake_bin}/git" \
  "${fixture_dir}/scripts/compose.sh" \
  "${fixture_dir}/scripts/smoke-test.sh"

if bash "${INFRA_DIR}/scripts/deploy-infra.sh" "${sha}" >/dev/null 2>&1; then
  fail "Infra 경로를 생략한 배포가 허용되었습니다."
fi

: >"${events_file}"
# SSH와 같은 파이프 입력으로 전달, 마지막 배포 단계까지 실행 확인.
# shellcheck disable=SC2002 # SSH 파이프 입력 재현을 위한 cat 유지.
cat "${INFRA_DIR}/scripts/deploy-infra.sh" | \
  MODE_TEST_EVENTS="${events_file}" MODE_TEST_RULE_ENGINE="${INFRA_DIR}/scripts/rule-engine.sh" \
  PATH="${fake_bin}:${PATH}" bash -s -- "${fixture_dir}" "${sha}" \
  >"${output_file}"

assert_not_contains "Eureka 등록 확인: FRONTEND" "${output_file}" \
  "Registry 조회 전용 Frontend의 Eureka 등록을 기다렸습니다."
assert_contains "Eureka 등록 확인: GATEWAY-SERVICE" "${output_file}" \
  "Gateway의 Eureka 등록 확인이 누락되었습니다."
assert_contains "Eureka 등록 확인: IDENTITY-SERVICE" "${output_file}" \
  "Identity의 Eureka 등록 확인이 누락되었습니다."
assert_contains "Eureka 등록 확인: LEARNING-SERVICE" "${output_file}" \
  "Learning의 Eureka 등록 확인이 누락되었습니다."
assert_contains "--remove-orphans" "${events_file}" \
  "전체 배포에서 이전 Rule Container 정리가 누락되었습니다."
assert_contains "rule-rollout:${fixture_dir}/deploy.env" "${events_file}" \
  "전체 배포에서 Rule 롤아웃이 누락되었습니다."
assert_contains "smoke:https://example.invalid" "${events_file}" \
  "전체 배포 Smoke Test가 누락되었습니다."
assert_before "nginx nginx -t" \
  "nginx nginx -s reload" "${events_file}" \
  "Nginx 설정 검증이 reload보다 먼저 실행되지 않았습니다."
assert_before "nginx nginx -s reload" \
  "smoke:https://example.invalid" "${events_file}" \
  "Nginx reload가 Smoke Test보다 먼저 실행되지 않았습니다."
assert_contains "인프라 배포 완료" "${output_file}" \
  "전체 배포 완료 상태가 명시되지 않았습니다."

# 기존 관측 파일의 읽기·디렉터리 탐색 권한 복구와 새 Git 파일의 권한 확인.
for public_file in \
  "${fixture_dir}/observability/filebeat/filebeat.yml" \
  "${fixture_dir}/observability/elastalert2/runtime.py" \
  "${fixture_dir}/checkout-fixture/public.conf"; do
  mode="$(stat -c '%a' "${public_file}" 2>/dev/null || stat -f '%Lp' "${public_file}")"
  [[ "${mode}" == 644 ]] || fail "공개 파일의 읽기 권한 복구 실패: ${public_file}"
done
for public_directory in \
  "${fixture_dir}/observability/elasticsearch" \
  "${fixture_dir}/observability/elastalert2/rules" \
  "${fixture_dir}/checkout-fixture"; do
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
if MODE_TEST_EVENTS="${events_file}" \
  MODE_TEST_RULE_ENGINE="${INFRA_DIR}/scripts/rule-engine.sh" \
  MODE_TEST_FAIL_NGINX_RELOAD=true \
  PATH="${fake_bin}:${PATH}" \
  bash "${INFRA_DIR}/scripts/deploy-infra.sh" \
    "${fixture_dir}" "${sha}" >/dev/null 2>&1; then
  fail "Nginx reload 실패가 전체 배포 실패로 전파되지 않았습니다."
fi
assert_not_contains "smoke:" "${events_file}" \
  "Nginx reload 실패 이후 Smoke Test가 실행되었습니다."

echo "Deploy infra tests passed"
