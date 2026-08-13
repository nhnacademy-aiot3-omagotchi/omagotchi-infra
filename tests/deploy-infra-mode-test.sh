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
touch "${fixture_dir}/deploy.env" "${fixture_dir}/../secrets/prod.env"

cat >"${fake_bin}/git" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  branch) printf 'main\n' ;;
  status) ;;
  rev-parse) printf '0000000000000000000000000000000000000000\n' ;;
  fetch | cat-file | merge-base | merge) ;;
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
EOF

cat >"${fixture_dir}/scripts/smoke-test.sh" <<'EOF'
#!/usr/bin/env bash
printf 'smoke:%s\n' "$*" >>"${MODE_TEST_EVENTS}"
EOF

cat >"${fixture_dir}/scripts/rule-engine.sh" <<'EOF'
wait_eureka_application() {
  printf 'eureka:%s\n' "$2" >>"${MODE_TEST_EVENTS}"
}

rollout_rule_engine_infra() {
  printf 'rule-rollout:%s\n' "$1" >>"${MODE_TEST_EVENTS}"
}
EOF

chmod +x \
  "${fake_bin}/flock" \
  "${fake_bin}/git" \
  "${fixture_dir}/scripts/compose.sh" \
  "${fixture_dir}/scripts/smoke-test.sh"

: >"${events_file}"
MODE_TEST_EVENTS="${events_file}" PATH="${fake_bin}:${PATH}" \
  bash "${INFRA_DIR}/scripts/deploy-infra.sh" --skip-rule "${fixture_dir}" "${sha}" \
  >"${output_file}"

assert_not_contains "rule-rollout:" "${events_file}" \
  "Rule 제외 배포에서 Rule 롤아웃이 실행되었습니다."
assert_not_contains "--remove-orphans" "${events_file}" \
  "Rule 제외 배포에서 기존 Rule Container 정리가 실행되었습니다."
assert_contains "smoke:--skip-rule" "${events_file}" \
  "Rule 제외 Smoke Test 옵션이 전달되지 않았습니다."
assert_contains "인프라 부분 배포 완료" "${output_file}" \
  "Rule 제외 배포 완료 상태가 명시되지 않았습니다."

: >"${events_file}"
MODE_TEST_EVENTS="${events_file}" PATH="${fake_bin}:${PATH}" \
  bash "${INFRA_DIR}/scripts/deploy-infra.sh" "${fixture_dir}" "${sha}" \
  >"${output_file}"

assert_contains "--remove-orphans" "${events_file}" \
  "전체 배포에서 이전 Rule Container 정리가 누락되었습니다."
assert_contains "rule-rollout:${fixture_dir}/deploy.env" "${events_file}" \
  "전체 배포에서 Rule 롤아웃이 누락되었습니다."
assert_contains "smoke:" "${events_file}" \
  "전체 배포 Smoke Test가 누락되었습니다."
assert_not_contains "smoke:--skip-rule" "${events_file}" \
  "전체 배포에서 Rule Smoke Test가 제외되었습니다."

echo "Deploy infra mode tests passed"
